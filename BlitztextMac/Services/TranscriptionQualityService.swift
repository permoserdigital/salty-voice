import Foundation

enum TranscriptionQualityService {
    static let minimumRecordingDuration: TimeInterval = 0.3

    static func shouldRejectRecording(duration: TimeInterval) -> Bool {
        duration < minimumRecordingDuration
    }

    static func cleanedTranscript(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Phrases Whisper hallucinates on silence or near-empty audio. They come
    /// from subtitle credits in the model's training data (e.g. Amara/ZDF)
    /// and are not something a user would dictate.
    private static let knownHallucinationMarkers: [String] = [
        "amara.org",
        "untertitelung des zdf",
        "untertitel im auftrag des zdf",
        "untertitel von stephanie geiges",
        "subtitles by the amara",
        "copyright wdr",
    ]

    static func isKnownHallucination(_ text: String) -> Bool {
        let lowercased = cleanedTranscript(text).lowercased()
        guard !lowercased.isEmpty else { return false }
        return knownHallucinationMarkers.contains { lowercased.contains($0) }
    }

    static func isLikelyArtifact(_ text: String, recordingDuration: TimeInterval) -> Bool {
        let cleaned = cleanedTranscript(text)
        guard !cleaned.isEmpty else { return true }

        if isKnownHallucination(cleaned) {
            return true
        }

        let words = cleaned.split { $0.isWhitespace || $0.isNewline }
        let letters = cleaned.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count

        if letters == 0 {
            return true
        }

        if recordingDuration < 0.55 && (words.count >= 5 || cleaned.count >= 32) {
            return true
        }

        if recordingDuration < 0.8 && cleaned.count >= 56 {
            return true
        }

        return false
    }
}
