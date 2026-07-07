import AppKit
import SwiftUI
import Observation

// MARK: - Shared model

@Observable
@MainActor
final class StatusIndicatorModel {
    var status: MenuBarStatus = .idle
    /// Seconds until the recording limit; non-nil only in the last minute.
    var countdown: Int?
}

// MARK: - Base controller (floating, non-activating HUD panel)

@MainActor
class FloatingIndicatorController {
    let model = StatusIndicatorModel()
    private(set) var panel: NSPanel?

    /// Lets the app suppress the indicator (e.g. while the popover is open).
    var isSuppressed: () -> Bool = { false }

    func update(to status: MenuBarStatus) {
        model.status = status

        switch status {
        case .recording, .processing, .success, .error:
            guard !isSuppressed() else {
                hide()
                return
            }
            show()
        case .idle:
            hide()
        }
    }

    // Subclasses provide content + geometry.
    var panelSize: NSSize { NSSize(width: 100, height: 40) }
    func makeContentView() -> NSView { NSView() }
    func reposition(_ panel: NSPanel) {}
    func didShow() {}
    func didHide() {}

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let newPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        newPanel.isFloatingPanel = true
        newPanel.level = .statusBar
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = false
        newPanel.ignoresMouseEvents = true
        newPanel.hidesOnDeactivate = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.contentView = makeContentView()

        panel = newPanel
        return newPanel
    }

    /// Invalidates any in-flight fade-out so its completion cannot hide a
    /// panel that was re-shown in the meantime.
    private var hideToken = UUID()

    private func show() {
        hideToken = UUID()
        let panel = ensurePanel()
        reposition(panel)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        didShow()
    }

    private func hide() {
        didHide()
        guard let panel, panel.isVisible else { return }
        let token = UUID()
        hideToken = token
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor [weak self] in
                guard let self, self.hideToken == token else { return }
                self.panel?.orderOut(nil)
            }
        })
    }
}

// MARK: - Speech bubble below the menu bar icon

@MainActor
final class StatusBubbleController: FloatingIndicatorController {
    private weak var statusButton: NSStatusBarButton?

    func attach(to button: NSStatusBarButton) {
        statusButton = button
    }

    override var panelSize: NSSize { NSSize(width: 96, height: 36) }

    override func makeContentView() -> NSView {
        NSHostingView(rootView: StatusBubbleView(model: model))
    }

    override func reposition(_ panel: NSPanel) {
        guard let button = statusButton, let window = button.window else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(buttonRect)
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: screenRect.midX - size.width / 2,
            y: screenRect.minY - size.height - 2
        ))
    }
}

// MARK: - Indicator following the mouse pointer

@MainActor
final class CursorIndicatorController: FloatingIndicatorController {
    private var followTimer: Timer?

    override var panelSize: NSSize { NSSize(width: 76, height: 30) }

    override func makeContentView() -> NSView {
        NSHostingView(rootView: CursorIndicatorView(model: model))
    }

    override func reposition(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x + 16, y: mouse.y - size.height / 2)

        // Flip to the left side when the pointer is near the right screen edge.
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let visible = screen.visibleFrame
            if origin.x + size.width > visible.maxX {
                origin.x = mouse.x - size.width - 16
            }
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }

        panel.setFrameOrigin(origin)
    }

    override func didShow() {
        guard followTimer == nil else { return }
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.reposition(panel)
            }
        }
        RunLoop.main.add(followTimer!, forMode: .common)
    }

    override func didHide() {
        followTimer?.invalidate()
        followTimer = nil
    }
}

// MARK: - Views

private let indicatorBackground = Color.black.opacity(0.82)

struct StatusBubbleView: View {
    let model: StatusIndicatorModel

    var body: some View {
        VStack(spacing: 0) {
            BubbleTail()
                .fill(indicatorBackground)
                .frame(width: 10, height: 4)

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(indicatorBackground)

                StatusIndicatorContent(model: model)
                    .padding(.horizontal, 8)
            }
            .frame(width: 72, height: 22)
        }
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CursorIndicatorView: View {
    let model: StatusIndicatorModel

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(indicatorBackground)

            StatusIndicatorContent(model: model)
                .padding(.horizontal, 8)
        }
        .frame(width: 60, height: 20)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shared animated content: waveform while recording, pulsing dots while
/// processing, short check/exclamation flash on completion.
struct StatusIndicatorContent: View {
    let model: StatusIndicatorModel

    var body: some View {
        switch model.status {
        case .recording:
            if let seconds = model.countdown {
                // Last minute before the recording limit: show a countdown.
                HStack(spacing: 5) {
                    PulsingDot(color: .red)
                    Text("\(seconds / 60):" + String(format: "%02d", seconds % 60))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
            } else {
                HStack(spacing: 5) {
                    PulsingDot(color: .red)
                    WaveBars()
                }
            }
        case .processing:
            ProcessingDots()
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }
}

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct PulsingDot: View {
    let color: Color
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .opacity(animate ? 1.0 : 0.35)
            .animation(
                .easeInOut(duration: 0.55).repeatForever(autoreverses: true),
                value: animate
            )
            .onAppear { animate = true }
    }
}

private struct WaveBars: View {
    @State private var animate = false
    private let peaks: [CGFloat] = [0.55, 1.0, 0.7, 0.9, 0.5]

    var body: some View {
        HStack(spacing: 2.2) {
            ForEach(0..<peaks.count, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 2.2, height: 12)
                    .scaleEffect(y: animate ? peaks[index] : 0.2, anchor: .center)
                    .animation(
                        .easeInOut(duration: 0.32)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.07),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

private struct ProcessingDots: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.white)
                    .frame(width: 4.5, height: 4.5)
                    .opacity(animate ? 1.0 : 0.25)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}
