import Foundation

/// Term span merging and highlight segmentation — port of transcript-merger.
enum TermMerger {
    static func merge(_ previous: [TranscriptTerm], _ incoming: [TranscriptTerm]) -> [TranscriptTerm] {
        var map: [String: TranscriptTerm] = [:]
        for term in previous + incoming {
            map[term.id] = term
        }
        return map.values.sorted { a, b in
            a.start != b.start ? a.start < b.start : a.end > b.end
        }
    }

    enum Segment: Identifiable {
        case text(String, start: Int)
        case term(String, TranscriptTerm)

        var id: String {
            switch self {
            case .text(_, let start): "t\(start)"
            case .term(_, let term): term.id
            }
        }
    }

    /// Splits `text` into plain/term segments. Term offsets are UTF-16-agnostic
    /// here: the backend indexes by character positions of the transcript string,
    /// matching JS string slicing, so we index by Character too.
    static func highlightSegments(text: String, terms: [TranscriptTerm]) -> [Segment] {
        let characters = Array(text)
        guard !characters.isEmpty, !terms.isEmpty else {
            return text.isEmpty ? [] : [.text(text, start: 0)]
        }

        let spans = normalizeSpans(count: characters.count, terms: terms)
        var segments: [Segment] = []
        var cursor = 0

        for term in spans {
            if term.start > cursor {
                segments.append(.text(String(characters[cursor..<term.start]), start: cursor))
            }
            segments.append(.term(String(characters[term.start..<term.end]), term))
            cursor = term.end
        }
        if cursor < characters.count {
            segments.append(.text(String(characters[cursor...]), start: cursor))
        }
        return segments
    }

    /// Deduplicates and resolves overlaps preferring longer spans.
    private static func normalizeSpans(count: Int, terms: [TranscriptTerm]) -> [TranscriptTerm] {
        var unique: [String: TranscriptTerm] = [:]
        for term in terms where term.start >= 0 && term.end <= count && term.start < term.end {
            unique[term.id] = term
        }

        let sorted = unique.values.sorted { a, b in
            a.start != b.start ? a.start < b.start : a.length > b.length
        }

        var selected: [TranscriptTerm] = []
        for span in sorted {
            if let overlapIndex = selected.firstIndex(where: { $0.start < span.end && span.start < $0.end }) {
                if span.length > selected[overlapIndex].length {
                    selected[overlapIndex] = span
                }
            } else {
                selected.append(span)
            }
        }
        return selected.sorted { $0.start < $1.start }
    }
}
