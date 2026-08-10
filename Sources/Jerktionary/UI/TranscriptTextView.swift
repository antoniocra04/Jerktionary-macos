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
        /// What is currently in the text storage, so the next update can diff
        /// against it without reading it back out of TextKit.
        var applied = NSAttributedString()
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
        coordinator.sourceText = text
        coordinator.sourceTerms = terms

        let document = TranscriptDocument.build(text: text, terms: terms)
        let previous = coordinator.applied
        // No equality check against `previous` here: it would be another full
        // pass over the document, and if the two do match the diff below simply
        // resolves to an empty replacement.
        coordinator.termsByID = Dictionary(terms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        guard let storage = textView.textStorage else { return }
        let unchanged = TranscriptDocument.unchangedPrefixLength(previous, document)
        let replaced = NSRange(location: unchanged, length: previous.length - unchanged)
        let tail = document.attributedSubstring(
            from: NSRange(location: unchanged, length: document.length - unchanged)
        )

        // Selections that survive the edit are worth keeping — the user may be
        // copying from earlier in the transcript while speech continues.
        let selection = textView.selectedRange()
        storage.beginEditing()
        storage.replaceCharacters(in: replaced, with: tail)
        storage.endEditing()
        if selection.upperBound <= unchanged {
            textView.setSelectedRange(selection)
        }
        coordinator.applied = document
    }
}

/// Builds the attributed transcript: plain runs plus tinted, underlined,
/// tappable runs for the recognised terms.
enum TranscriptDocument {
    static let linkScheme = "jerktionary-term"

    static func build(text: String, terms: [TranscriptTerm]) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
        let segments = TermMerger.highlightSegments(text: text, terms: terms)
        // NSMutableAttributedString appends in amortised constant time; building
        // this by `AttributedString +=` was quadratic in the segment count and
        // cost 38 ms at 100k characters on its own.
        let document = NSMutableAttributedString()
        for segment in segments {
            switch segment {
            case .text(let value, _):
                document.append(NSAttributedString(string: value, attributes: base))
            case .term(let value, let term):
                var attributes = base
                attributes[.foregroundColor] = NSColor.controlAccentColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                if let url = linkURL(for: term) {
                    attributes[.link] = url
                }
                document.append(NSAttributedString(string: value, attributes: attributes))
            }
        }
        return document
    }

    static func linkURL(for term: TranscriptTerm) -> URL? {
        let encoded = term.id.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? ""
        return URL(string: "\(linkScheme)://\(encoded)")
    }

    /// Length, in UTF-16 units, of the leading stretch the two documents share —
    /// same characters and same attributes. Everything from here on is replaced.
    static func unchangedPrefixLength(_ old: NSAttributedString, _ new: NSAttributedString) -> Int {
        let limit = min(old.length, new.length)
        guard limit > 0 else { return 0 }

        // Text first: attribute runs are only walked as far as the characters
        // actually match. Copied into buffers rather than compared through
        // `character(at:)`, which is an Objective-C call per character.
        var oldBuffer = [unichar](repeating: 0, count: limit)
        var newBuffer = [unichar](repeating: 0, count: limit)
        (old.string as NSString).getCharacters(&oldBuffer, range: NSRange(location: 0, length: limit))
        (new.string as NSString).getCharacters(&newBuffer, range: NSRange(location: 0, length: limit))
        var textPrefix = 0
        while textPrefix < limit, oldBuffer[textPrefix] == newBuffer[textPrefix] {
            textPrefix += 1
        }

        // Run boundaries are compared by attributes, not by extent: appending to
        // the transcript extends the final run rather than starting a new one,
        // and requiring equal run lengths would discard the whole tail since the
        // last term on every single update.
        // `build` sets tint, underline and link together on exactly the term
        // runs, so the link alone identifies a run — and reading one attribute
        // avoids bridging a whole dictionary per run, of which there are one
        // per term.
        var location = 0
        while location < textPrefix {
            var oldRange = NSRange(location: 0, length: 0)
            var newRange = NSRange(location: 0, length: 0)
            let oldLink = old.attribute(.link, at: location, effectiveRange: &oldRange) as? URL
            let newLink = new.attribute(.link, at: location, effectiveRange: &newRange) as? URL
            guard oldLink == newLink else { break }
            let next = min(oldRange.upperBound, newRange.upperBound, textPrefix)
            guard next > location else { break }
            location = next
        }
        return location
    }

    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        return style
    }()
}
