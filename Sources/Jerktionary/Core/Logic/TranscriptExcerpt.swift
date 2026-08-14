import Foundation

/// Extracts a stable tail of the transcript only after an explicit user action.
/// It deliberately does not try to decide whether the text is a question.
enum TranscriptExcerpt {
    private static let scanWindow = 2_000

    static func latest(in text: String, sentenceLimit: Int = 2) -> String? {
        let tail = String(text.suffix(scanWindow))
        let sentences = splitSentences(tail)
        guard !sentences.isEmpty else { return nil }

        let excerpt = sentences
            .suffix(max(1, sentenceLimit))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[.…]+$", with: "", options: .regularExpression)

        return excerpt.isEmpty ? nil : excerpt
    }

    static func splitSentences(_ text: String) -> [String] {
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
}
