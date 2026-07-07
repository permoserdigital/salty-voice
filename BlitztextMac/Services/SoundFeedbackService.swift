import AppKit

enum SoundFeedbackEvent {
    case recordingStarted
    case recordingStopped
    case success
    case cancelled
    case error
    case limitWarning
}

/// Plays short, quiet system sounds for status transitions.
/// Controlled by the "Ton-Feedback" setting.
enum SoundFeedbackService {
    /// Injected once at startup so the static service can read the setting.
    static var isEnabled: () -> Bool = { true }

    static func play(_ event: SoundFeedbackEvent) {
        guard isEnabled() else { return }

        let name: String
        let volume: Float
        switch event {
        case .recordingStarted:
            (name, volume) = ("Pop", 0.18)
        case .recordingStopped:
            (name, volume) = ("Tink", 0.15)
        case .success:
            (name, volume) = ("Glass", 0.2)
        case .cancelled:
            (name, volume) = ("Bottle", 0.18)
        case .error:
            (name, volume) = ("Basso", 0.2)
        case .limitWarning:
            (name, volume) = ("Ping", 0.3)
        }

        guard let sound = NSSound(named: name) else { return }
        sound.volume = volume
        sound.play()
    }
}
