import AppKit
import SwiftUI

/// A plain-text editor backed directly by NSTextView.
///
/// SwiftUI's `TextEditor` cannot be used for long notes: every keystroke pushes
/// the whole document string through SwiftUI's state graph, which costs time
/// proportional to the document — ~240 ms per keystroke in a 200k-character
/// note. Measured against the same edit, a bare NSTextView stays at ~1 ms
/// regardless of length, because TextKit edits its storage in place.
///
/// So the live text deliberately never enters SwiftUI state. Edits go to a
/// caller-owned buffer through `onEdit`, and the view only writes into the text
/// storage when `documentID` changes — that is, when a different note is opened.
struct NoteTextEditor: NSViewRepresentable {
    /// Identifies the document currently loaded in the text view. A change here
    /// (and only here) replaces the contents.
    let documentID: String
    /// Read once per `documentID`; later edits are not pushed back in.
    let initialText: String
    let onEdit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(documentID: documentID, onEdit: onEdit)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var documentID: String
        var onEdit: (String) -> Void

        init(documentID: String, onEdit: @escaping (String) -> Void) {
            self.documentID = documentID
            self.onEdit = onEdit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onEdit(textView.string)
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.setAccessibilityLabel("Текст заметки")
        textView.setAccessibilityHelp("Редактор Markdown")
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.widthTracksTextView = true
        // Lets TextKit lay out only what's on screen instead of the whole note.
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.string = initialText
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onEdit = onEdit
        // Never re-apply the text for the note already loaded: that is exactly
        // the full-document relayout this view exists to avoid.
        guard context.coordinator.documentID != documentID else { return }
        context.coordinator.documentID = documentID
        if let textView = scrollView.documentView as? NSTextView {
            textView.string = initialText
        }
    }
}
