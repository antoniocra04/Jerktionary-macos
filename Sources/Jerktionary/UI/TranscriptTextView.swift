import AppKit
import SwiftUI

/// Read-only transcript rendered by NSTextView.
///
/// The transcript grows for the whole meeting and used to be a single SwiftUI
/// `Text`, which re-laid-out the entire document on every update: 359 ms per
/// update at 50k characters, 789 ms at 100k, rising with the length of the
/// meeting. NSTextView lays out only the visible viewport, and this view
/// replaces just the tail that actually changed, so the cost tracks the size of
/// the update rather than the size of the transcript.
struct TranscriptTextView: NSViewRepresentable {
    let text: String
    let terms: [TranscriptTerm]
    let onTermTap: (TranscriptTerm) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTermTap: onTermTap) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onTermTap: (TranscriptTerm) -> Void
        var termsByID: [String: TranscriptTerm] = [:]
        /// The inputs `applied` was built from. `updateNSView` runs on every
        /// AppStore publish — typing in the meeting-context field, an answer
        /// arriving — and rebuilding the document each time would be wasted work.
        var sourceText: String?
        var sourceTerms: [TranscriptTerm] = []

        init(onTermTap: @escaping (TranscriptTerm) -> Void) {
            self.onTermTap = onTermTap
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL? = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, url.scheme == TranscriptDocument.linkScheme,
                  let host = url.host?.removingPercentEncoding,
                  let term = termsByID[host]
            else { return false }
            onTermTap(term)
            return true
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.setAccessibilityLabel("Transcript")
        textView.setAccessibilityHelp("Terms are underlined and open an explanation")
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.linkTextAttributes = [:] // styling comes from the document itself
        apply(to: textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onTermTap = onTermTap
        guard let textView = scrollView.documentView as? NSTextView else { return }
        apply(to: textView, coordinator: context.coordinator)
    }

    private func apply(to textView: NSTextView, coordinator: Coordinator) {
        guard coordinator.sourceText != text || coordinator.sourceTerms != terms else { return }
        let previousText = coordinator.sourceText ?? ""
        let previousTerms = coordinator.sourceTerms
        let commonCharacters = TranscriptDocument.commonPrefixCharacterCount(previousText, text)
        let changedTermStart = TranscriptDocument.earliestChangedTermStart(previousTerms, terms)
        let initialRebuildCharacter = min(commonCharacters, changedTermStart ?? commonCharacters)
        let overlappingTermStart = (previousTerms + terms)
            .filter { $0.start < initialRebuildCharacter && $0.end > initialRebuildCharacter }
            .map(\.start)
            .min()
        let rebuildCharacter = min(initialRebuildCharacter, overlappingTermStart ?? initialRebuildCharacter)
        let oldUTF16 = TranscriptDocument.utf16Offset(
            forCharacterOffset: rebuildCharacter,
            in: previousText
        )
        let newIndex = text.index(text.startIndex, offsetBy: rebuildCharacter)
        let tailText = String(text[newIndex...])
        let tail = TranscriptDocument.build(
            text: tailText,
            terms: terms,
            characterOffset: rebuildCharacter
        )

        coordinator.termsByID = Dictionary(terms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        guard let storage = textView.textStorage else { return }
        let replaced = NSRange(location: oldUTF16, length: storage.length - oldUTF16)

        // Selections that survive the edit are worth keeping — the user may be
        // copying from earlier in the transcript while speech continues.
        let selection = textView.selectedRange()
        storage.beginEditing()
        storage.replaceCharacters(in: replaced, with: tail)
        storage.endEditing()
        if selection.upperBound <= oldUTF16 {
            textView.setSelectedRange(selection)
        }
        coordinator.sourceText = text
        coordinator.sourceTerms = terms
    }
}

/// Builds the attributed transcript: plain runs plus tinted, underlined,
/// tappable runs for the recognised terms.
enum TranscriptDocument {
    static let linkScheme = "jerktionary-term"

    static func build(
        text: String,
        terms: [TranscriptTerm],
        characterOffset: Int = 0
    ) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
        let upperBound = characterOffset + text.count
        var originalsByAdjustedID: [String: TranscriptTerm] = [:]
        let adjustedTerms = terms.compactMap { term -> TranscriptTerm? in
            guard term.start >= characterOffset, term.end <= upperBound else { return nil }
            let adjusted = TranscriptTerm(
                text: term.text,
                normalized: term.normalized,
                start: term.start - characterOffset,
                end: term.end - characterOffset,
                type: term.type,
                confidence: term.confidence
            )
            originalsByAdjustedID[adjusted.id] = term
            return adjusted
        }
        let segments = TermMerger.highlightSegments(text: text, terms: adjustedTerms)
        // NSMutableAttributedString appends in amortised constant time; building
        // this by `AttributedString +=` was quadratic in the segment count and
        // cost 38 ms at 100k characters on its own.
        let document = NSMutableAttributedString()
        for segment in segments {
            switch segment {
            case .text(let value, _):
                document.append(NSAttributedString(string: value, attributes: base))
            case .term(let value, let adjustedTerm):
                var attributes = base
                attributes[.foregroundColor] = NSColor.controlAccentColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                let originalTerm = originalsByAdjustedID[adjustedTerm.id] ?? adjustedTerm
                if let url = linkURL(for: originalTerm) {
                    attributes[.link] = url
                }
                document.append(NSAttributedString(string: value, attributes: attributes))
            }
        }
        return document
    }

    static func commonPrefixCharacterCount(_ old: String, _ new: String) -> Int {
        var oldIndex = old.startIndex
        var newIndex = new.startIndex
        var count = 0
        while oldIndex < old.endIndex, newIndex < new.endIndex,
              old[oldIndex] == new[newIndex] {
            count += 1
            old.formIndex(after: &oldIndex)
            new.formIndex(after: &newIndex)
        }
        return count
    }

    static func utf16Offset(forCharacterOffset offset: Int, in text: String) -> Int {
        guard offset > 0 else { return 0 }
        let index = text.index(text.startIndex, offsetBy: min(offset, text.count))
        return text[..<index].utf16.count
    }

    static func earliestChangedTermStart(
        _ old: [TranscriptTerm],
        _ new: [TranscriptTerm]
    ) -> Int? {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newByID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(oldByID.keys).union(newByID.keys).compactMap { key in
            guard oldByID[key] != newByID[key] else { return nil }
            return min(oldByID[key]?.start ?? .max, newByID[key]?.start ?? .max)
        }.min()
    }

    static func linkURL(for term: TranscriptTerm) -> URL? {
        let encoded = term.id.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? ""
        return URL(string: "\(linkScheme)://\(encoded)")
    }

    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        return style
    }()
}
