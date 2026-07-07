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

        switch event {
        case .recordingStarted:
            playSound(named: "Pop", volume: 0.18)
        case .recordingStopped:
            playSound(named: "Tink", volume: 0.15)
        case .success:
            // Same clean pop as the start sound, twice in quick
            // succession -- reads as "done" without a new timbre.
            playSound(named: "Pop", volume: 0.18)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                playSound(named: "Pop", volume: 0.24)
            }
        case .cancelled:
            playSound(named: "Bottle", volume: 0.18)
        case .error:
            playSound(named: "Basso", volume: 0.2)
        case .limitWarning:
            playSound(named: "Ping", volume: 0.3)
        }
    }

    private static func playSound(named name: String, volume: Float) {
        guard let sound = NSSound(named: name) else { return }
        sound.volume = volume
        sound.play()
    }
}
