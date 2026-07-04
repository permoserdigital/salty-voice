import Foundation

enum TranscriptionQualityService {
    static let minimumRecordingDuration: TimeInterval = 0.3

    static func shouldRejectRecording(duration: TimeInterval) -> Bool {
        duration < minimumRecordingDuration
    }

    static func cleanedTranscript(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replaces spoken variants of known terms with their canonical spelling.
    /// Matches case-insensitively and across spaces ("salty brands",
    /// "Saltybrands" -> "SALTYBRANDS") while preserving punctuation.
    static func enforceCanonicalTerms(_ text: String, terms: [String]) -> String {
        let canonicalTerms = terms
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 }
        guard !text.isEmpty, !canonicalTerms.isEmpty else { return text }

        // Map "normalized key" (lowercased, no spaces) -> canonical spelling.
        var termMap: [String: String] = [:]
        for term in canonicalTerms {
            let key = term.lowercased().replacingOccurrences(of: " ", with: "")
            if termMap[key] == nil { termMap[key] = term }
        }
        let maxTermWordCount = canonicalTerms
            .map { $0.split(separator: " ").count }
            .max() ?? 1
        let windowLimit = max(maxTermWordCount + 1, 2)

        let nsText = text as NSString
        let tokenRegex = try! NSRegularExpression(pattern: "\\S+")
        let tokens = tokenRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !tokens.isEmpty else { return text }

        let edgePunctuation = CharacterSet.alphanumerics.inverted

        struct Replacement {
            let range: NSRange
            let value: String
        }
        var replacements: [Replacement] = []
        var index = 0

        while index < tokens.count {
            var matched = false

            for windowSize in stride(from: min(windowLimit, tokens.count - index), through: 1, by: -1) {
                let window = tokens[index..<(index + windowSize)]
                let words = window.map { nsText.substring(with: $0.range) }
                let trimmedWords = words.map {
                    $0.trimmingCharacters(in: edgePunctuation)
                }
                let key = trimmedWords.joined().lowercased()
                guard !key.isEmpty, let canonical = termMap[key] else { continue }

                // Preserve punctuation around the matched words.
                let firstWord = words.first ?? ""
                let lastWord = words.last ?? ""
                let leading = String(firstWord.prefix(while: {
                    String($0).rangeOfCharacter(from: edgePunctuation) != nil
                }))
                let trailing = String(lastWord.reversed().prefix(while: {
                    String($0).rangeOfCharacter(from: edgePunctuation) != nil
                }).reversed())

                let combined = trimmedWords.joined(separator: " ")
                if combined != canonical {
                    let start = window.first!.range.location
                    let end = window.last!.range.location + window.last!.range.length
                    replacements.append(Replacement(
                        range: NSRange(location: start, length: end - start),
                        value: leading + canonical + trailing
                    ))
                }
                index += windowSize
                matched = true
                break
            }

            if !matched { index += 1 }
        }

        guard !replacements.isEmpty else { return text }

        var result = text as NSString
        for replacement in replacements.reversed() {
            result = result.replacingCharacters(in: replacement.range, with: replacement.value) as NSString
        }
        return result as String
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
