import Carbon.HIToolbox
import Foundation

/// Registers Escape as a system-wide hotkey WHILE a recording runs.
///
/// Global NSEvent keyDown monitors require the separate Input Monitoring
/// permission, which the app deliberately does not request. Carbon hotkeys
/// need no permission at all -- the trade-off is that they consume the key,
/// so Escape is only claimed during a recording and released immediately
/// afterwards.
@MainActor
final class EscapeCancelHotkey {
    var onEscape: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func register() {
        guard hotKeyRef == nil else { return }

        if eventHandler == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, _, userData in
                    guard let userData else { return noErr }
                    let hotkey = Unmanaged<EscapeCancelHotkey>
                        .fromOpaque(userData)
                        .takeUnretainedValue()
                    Task { @MainActor in
                        hotkey.onEscape?()
                    }
                    return noErr
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandler
            )
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x5356_4553), id: 1) // 'SVES'
        RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}
