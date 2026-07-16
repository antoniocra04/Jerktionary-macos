import Foundation

/// Question extraction from the running transcript — a port of
/// useLiveQuestion/full-context-answer sentence logic.
enum QuestionDetector {
    private static let interrogative = try! NSRegularExpression(
        pattern: "^(что такое|что это|что значит|как|почему|зачем|где|когда|кто|чем|в ч[её]м|чем отлич|расскажи|объясни|приведи|дай определение|опиши)",
        options: [.caseInsensitive]
    )

    static func splitSentences(_ text: String) -> [String] {
        // Split after sentence-ending punctuation followed by whitespace.
        var sentences: [String] = []
        var current = ""
        var previousWasTerminator = false
        for character in text {
            if previousWasTerminator, character.isWhitespace {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
                previousWasTerminator = false
                continue
            }
            current.append(character)
            previousWasTerminator = character == "." || character == "!" || character == "?"
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sentences.append(trimmed) }
        return sentences
    }

    /// The most recent question: the last "?" sentence, or the trailing sentence
    /// when it starts with an interrogative/imperative phrase.
    static func latestQuestion(in text: String) -> String? {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let sentences = splitSentences(text)

        for sentence in sentences.reversed() where sentence.hasSuffix("?") {
            return sentence
        }

        guard let last = sentences.last else { return nil }
        let range = NSRange(last.startIndex..., in: last)
        if interrogative.firstMatch(in: last, range: range) != nil {
            return trimTrailingPunctuation(last)
        }
        return nil
    }

    /// Up to two trailing sentences for the manual "answer now" hotkey, so a
    /// question split across a pause is still whole.
    static func forcedQuestion(in text: String) -> String? {
        let sentences = splitSentences(text)
        guard !sentences.isEmpty else { return nil }
        let forced = trimTrailingPunctuation(sentences.suffix(2).joined(separator: " "))
        return forced.isEmpty ? nil : forced
    }

    /// The single last sentence, for the full-context hotkey.
    static func lastSentence(in text: String) -> String? {
        let sentences = splitSentences(text)
        guard let last = sentences.last else { return nil }
        let cleaned = last.replacingOccurrences(of: "[.…!?]+$", with: "", options: .regularExpression)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func trimTrailingPunctuation(_ text: String) -> String {
        text.replacingOccurrences(of: "[.…]+$", with: "", options: .regularExpression)
    }

    // MARK: Canonical question key

    private static let fillerWord = try! NSRegularExpression(
        pattern: "^(?:а|ну|итак|так|вот|значит|короче)\\s+",
        options: [.caseInsensitive]
    )

    /// Canonical key: lowercase, drop punctuation, collapse spaces, strip up to
    /// two leading filler words — collapses Whisper re-decodes onto one question.
    static func questionKey(_ question: String) -> String {
        var normalized = question.lowercased()
        normalized = normalized.replacingOccurrences(
            of: "[^\\p{L}\\p{N}\\s]", with: "", options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        for _ in 0..<2 {
            let range = NSRange(normalized.startIndex..., in: normalized)
            guard let match = fillerWord.firstMatch(in: normalized, range: range),
                  let swiftRange = Range(match.range, in: normalized)
            else { break }
            normalized.removeSubrange(swiftRange)
        }
        return normalized.trimmingCharacters(in: .whitespaces)
    }
}
