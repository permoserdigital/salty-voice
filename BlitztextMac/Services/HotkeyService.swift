import Cocoa
import Observation
import os.log

enum HotkeyMode: String, Codable, CaseIterable, Identifiable {
    case hold    // Tasten halten = aufnehmen, loslassen = stoppen
    case toggle  // Einmal drücken = starten, nochmal/Escape = stoppen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hold: return "Halten"
        case .toggle: return "Drücken"
        }
    }

    var description: String {
        switch self {
        case .hold: return "Tasten halten zum Aufnehmen, loslassen zum Stoppen"
        case .toggle: return "Einmal drücken zum Starten, nochmal oder Escape zum Stoppen"
        }
    }
}

enum HotkeyEvent {
    case down(WorkflowType)  // Keys pressed
    case up(WorkflowType)    // Keys released (for hold mode)
    case cancel              // Escape pressed
}

@Observable
@MainActor
final class HotkeyService {
    private static let logger = Logger(subsystem: "app.blitztext.preview", category: "hotkeys")

    // Control-only hotkey tuning
    private static let ctrlHoldStartDelay: TimeInterval = 0.25  // hold this long before recording starts
    private static let ctrlDoubleTapWindow: TimeInterval = 0.35 // max gap between taps for hands-free

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var activeCombo: WorkflowType?  // Which combo is currently held

    // Control-only hotkey state (hold to talk, double tap = hands-free)
    private var ctrlPressedAt: Date?
    private var ctrlContaminated = false    // another key/click was used while Ctrl was down
    private var pendingHandsFreeStart = false  // second tap seen; start on clean release
    private var lastCtrlTapAt: Date?
    private var ctrlHoldTask: Task<Void, Never>?
    private var handsFreeActive = false

    var onHotkeyEvent: ((HotkeyEvent) -> Void)?

    func start() {
        Self.logger.info("HotkeyService starting, accessibility trusted: \(AXIsProcessTrusted())")
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
            }
            return event
        }
        // Escape cancels; any other key while Ctrl is held marks it as a
        // regular shortcut (e.g. Ctrl+C) so no recording is started.
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                if event.keyCode == 53 { // Escape
                    self?.handleEscape()
                } else {
                    self?.markCtrlContaminatedIfNeeded()
                }
            }
        }
        // Ctrl+click is a context click, not a dictation request.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.markCtrlContaminatedIfNeeded()
            }
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        globalMonitor = nil
        localMonitor = nil
        keyMonitor = nil
        mouseMonitor = nil
        ctrlHoldTask?.cancel()
    }

    private func handleFlags(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        Self.logger.debug("flagsChanged received, rawFlags: \(flags.rawValue)")

        // Control alone: hold to talk, or double-tap for hands-free mode
        if flags == [.control] {
            handleCtrlPressed()
            return
        }

        if flags.isEmpty {
            handleCtrlReleasedIfNeeded()
        } else if ctrlPressedAt != nil {
            // Another modifier joined (e.g. Ctrl+Shift) -> regular shortcut
            ctrlContaminated = true
            ctrlHoldTask?.cancel()
        }

        // While hands-free records, fn combos must not start a second
        // workflow on top of it.
        if handsFreeActive, flags.contains(.function) {
            return
        }

        // fn + Shift + Control -> local transcription
        if flags == [.function, .shift, .control] {
            if activeCombo == nil {
                activeCombo = .localTranscription
                onHotkeyEvent?(.down(.localTranscription))
            }
            return
        }

        // fn + Shift -> transcription
        if flags == [.function, .shift] {
            if activeCombo == nil {
                Self.logger.info("hotkey combo matched: fn+shift -> transcription")
                activeCombo = .transcription
                onHotkeyEvent?(.down(.transcription))
            }
            return
        }

        // fn + Control -> Textverbesserer
        if flags == [.function, .control] {
            if activeCombo == nil {
                activeCombo = .textImprover
                onHotkeyEvent?(.down(.textImprover))
            }
            return
        }

        // fn + Option -> Rage Mode
        if flags == [.function, .option] {
            if activeCombo == nil {
                activeCombo = .dampfAblassen
                onHotkeyEvent?(.down(.dampfAblassen))
            }
            return
        }

        // fn + Command -> Emoji Mode
        if flags == [.function, .command] {
            if activeCombo == nil {
                activeCombo = .emojiText
                onHotkeyEvent?(.down(.emojiText))
            }
            return
        }

        // Keys released -- fire up event
        if let combo = activeCombo {
            activeCombo = nil
            onHotkeyEvent?(.up(combo))
        }
    }

    private func handleEscape() {
        activeCombo = nil
        handsFreeActive = false
        pendingHandsFreeStart = false
        lastCtrlTapAt = nil
        ctrlHoldTask?.cancel()
        onHotkeyEvent?(.cancel)
    }

    // MARK: - Control-only hotkey (hold to talk + double-tap hands-free)

    private func handleCtrlPressed() {
        // Ignore while an fn combo is active or Ctrl is already tracked
        guard activeCombo == nil, ctrlPressedAt == nil else { return }

        ctrlPressedAt = Date()
        ctrlContaminated = false

        // While hands-free records, a Ctrl press only ARMS the stop.
        // The decision falls on release, so Ctrl+C during a hands-free
        // recording copies text without killing the recording.
        if handsFreeActive { return }

        // Second tap within the window ARMS hands-free; it only starts on a
        // clean release, so the Ctrl of a Ctrl+shortcut never triggers it.
        if let lastTap = lastCtrlTapAt,
           Date().timeIntervalSince(lastTap) < Self.ctrlDoubleTapWindow {
            pendingHandsFreeStart = true
            return
        }

        // Single press: start hold-to-talk only after a short delay so
        // regular Ctrl shortcuts (Ctrl+C, Ctrl+click, ...) stay untouched.
        ctrlHoldTask?.cancel()
        ctrlHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.ctrlHoldStartDelay))
            guard let self, !Task.isCancelled else { return }
            guard self.ctrlPressedAt != nil,
                  !self.ctrlContaminated,
                  !self.pendingHandsFreeStart,
                  self.activeCombo == nil,
                  !self.handsFreeActive else { return }
            Self.logger.info("ctrl hold -> transcription")
            self.activeCombo = .transcription
            self.onHotkeyEvent?(.down(.transcription))
        }
    }

    private func handleCtrlReleasedIfNeeded() {
        guard let pressedAt = ctrlPressedAt else { return }
        ctrlHoldTask?.cancel()
        ctrlPressedAt = nil

        let duration = Date().timeIntervalSince(pressedAt)
        let cleanTap = !ctrlContaminated && duration < Self.ctrlHoldStartDelay

        // Clean tap while hands-free records -> stop and transcribe.
        if handsFreeActive {
            if cleanTap {
                handsFreeActive = false
                Self.logger.info("ctrl tap -> hands-free stop")
                onHotkeyEvent?(.up(.transcription))
            }
            return
        }

        // Armed double tap -> start hands-free only on a clean release.
        if pendingHandsFreeStart {
            pendingHandsFreeStart = false
            lastCtrlTapAt = nil
            if cleanTap {
                handsFreeActive = true
                Self.logger.info("ctrl double tap -> hands-free start")
                onHotkeyEvent?(.down(.transcription))
            }
            return
        }

        // Clean single tap becomes a double-tap candidate.
        if cleanTap {
            lastCtrlTapAt = Date()
        }
        // Note: if hold-to-talk was running, activeCombo is set and the
        // generic release branch in handleFlags fires the .up event.
    }

    private func markCtrlContaminatedIfNeeded() {
        guard ctrlPressedAt != nil else { return }
        ctrlContaminated = true
        ctrlHoldTask?.cancel()
        // If recording already started via Ctrl hold, a typed key means
        // this was meant as a shortcut -- cancel instead of transcribing.
        if activeCombo == .transcription, !handsFreeActive {
            activeCombo = nil
            onHotkeyEvent?(.cancel)
        }
    }
}
