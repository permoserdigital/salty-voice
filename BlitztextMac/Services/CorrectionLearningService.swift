import AppKit
import ApplicationServices

/// After a paste, watches briefly whether the user manually corrected a word
/// and learns the corrected spelling as a personal term.
///
/// Deliberately conservative: it only learns capitalized words (names,
/// brands), at most two per paste, and only when the pasted text is still
/// mostly present in the field -- so casual rewrites never pollute the list.
enum CorrectionLearningService {
    static let watchDelay: TimeInterval = 8
    static let maxLearnedPerPaste = 2

    /// Reads the focused UI element's text via the Accessibility API.
    /// Returns nil for apps/fields that do not expose their value.
    @MainActor
    static func focusedElementText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else { return nil }

        let element = focusedRef as! AXUIElement
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success, let text = valueRef as? String, !text.isEmpty else {
            return nil
        }
        return text
    }

    /// Compares the pasted text with the field's current content and returns
    /// manually corrected words worth learning.
    static func learnedCorrections(
        pastedText: String,
        currentText: String,
        knownTerms: [String]
    ) -> [String] {
        let pastedWords = tokenize(pastedText)
        let currentWords = tokenize(currentText)
        guard pastedWords.count >= 3, !currentWords.isEmpty else { return [] }

        // The paste must still be mostly there; otherwise the user moved on
        // to something else and a diff would only produce noise.
        let currentLower = Set(currentWords.map { $0.lowercased() })
        let stillPresent = pastedWords.filter { currentLower.contains($0.lowercased()) }
        guard Double(stillPresent.count) / Double(pastedWords.count) >= 0.6 else { return [] }

        let pastedLower = Set(pastedWords.map { $0.lowercased() })
        let knownLower = Set(knownTerms.map { $0.lowercased() })
        let removedWords = pastedWords.filter { !currentLower.contains($0.lowercased()) }

        var learned: [String] = []
        for word in orderedUnique(currentWords) {
            guard learned.count < maxLearnedPerPaste else { break }
            guard word.count >= 4,
                  word != word.lowercased(),                    // names/brands only
                  !knownLower.contains(word.lowercased()) else { continue }

            if pastedLower.contains(word.lowercased()) {
                // Same word, user only fixed the casing (salty -> SALTY).
                if let original = pastedWords.first(where: { $0.lowercased() == word.lowercased() }),
                   original != word {
                    learned.append(word)
                }
            } else {
                // New word that closely resembles a removed one -> a respelling.
                let lower = word.lowercased()
                if removedWords.contains(where: {
                    levenshtein($0.lowercased(), lower) <= max(1, lower.count / 3)
                }) {
                    learned.append(word)
                }
            }
        }
        return learned
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split { $0.isWhitespace || $0.isNewline }
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }
    }

    private static func orderedUnique(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted }
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a), bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)

        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }
}
