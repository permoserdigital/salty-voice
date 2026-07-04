import Foundation

enum TranscriptionQualityService {
    static let minimumRecordingDuration: TimeInterval = 0.3

    /// Peaks below this normalized level (0...1) mean the recording only
    /// captured silence -- transcribing it would just invite hallucinations.
    static let minimumPeakLevel: Float = 0.18

    static func shouldRejectRecording(duration: TimeInterval, peakLevel: Float) -> Bool {
        duration < minimumRecordingDuration || peakLevel < minimumPeakLevel
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
        // German subtitle credits
        "amara.org",
        "untertitelung des zdf",
        "untertitel im auftrag des zdf",
        "untertitel von stephanie geiges",
        "subtitles by the amara",
        "copyright wdr",
        // English video outros
        "thank you for watching",
        "thanks for watching",
        "don't forget to subscribe",
        "please subscribe",
        // Korean news/video outros
        "mbc 뉴스",
        "kbs 뉴스",
        "sbs 뉴스",
        "뉴스 이덕영",
        "구독과 좋아요",
        "시청해 주셔서 감사합니다",
        // Japanese outros
        "ご視聴ありがとうございました",
        "チャンネル登録",
        // Misc known silence artifacts
        "www.mooji.org",
        "so much for watching",
        "for watching",
        "legendas pela comunidade",
        "sous-titres réalisés",
    ]

    /// Whole-output phrases Whisper produces for silence. Only rejected when
    /// they are the ENTIRE result, so real dictation is never affected.
    private static let exactSilenceOutputs: Set<String> = [
        "you", "you you you",
        "thank you", "thanks", "thank you so much",
        "bye", "goodbye", "the end",
        "é isso aí", "obrigado", "gracias",
    ]

    static func isKnownHallucination(_ text: String) -> Bool {
        let lowercased = cleanedTranscript(text).lowercased()
        guard !lowercased.isEmpty else { return false }

        if knownHallucinationMarkers.contains(where: { lowercased.contains($0) }) {
            return true
        }

        // Normalize punctuation away and compare against whole-output list.
        let normalized = lowercased
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return exactSilenceOutputs.contains(normalized)
    }

    static func isLikelyArtifact(_ text: String, recordingDuration: TimeInterval) -> Bool {
        let cleaned = cleanedTranscript(text)
        guard !cleaned.isEmpty else { return true }

        if isKnownHallucination(cleaned) {
            return true
        }

        let words = cleaned.split { $0.isWhitespace || $0.isNewline }
        let letterScalars = cleaned.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let letters = letterScalars.count

        if letters == 0 {
            return true
        }

        // Dictation happens in a Latin-script language. A result that is
        // mostly non-Latin script (Korean, Japanese, ...) is a classic
        // Whisper silence hallucination.
        let latinLetters = letterScalars.filter { $0.value < 0x250 }.count
        if letters >= 4, Double(latinLetters) / Double(letters) < 0.5 {
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
