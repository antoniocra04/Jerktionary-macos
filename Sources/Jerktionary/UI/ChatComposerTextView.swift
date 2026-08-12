import AppKit
import SwiftUI

/// The chat input: an NSTextView that reports edits through a closure instead of
/// a binding, so the draft never enters SwiftUI's state graph — the same reason
/// the note editor is built this way.
///
/// It also owns two behaviours SwiftUI's TextEditor cannot express: Enter sends
/// while Shift+Enter inserts a newline, and pasted images are intercepted before
/// AppKit turns them into attachment characters in the text.
struct ChatComposerTextView: NSViewRepresentable {
    /// Clears the field when it changes — a different conversation is open.
    let documentID: String
    let onEdit: (String) -> Void
    let onSubmit: () -> Void
    let onPasteImages: ([ChatAttachment]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(documentID: documentID, onEdit: onEdit, onSubmit: onSubmit, onPaste: onPasteImages)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var documentID: String
        var onEdit: (String) -> Void
        var onSubmit: () -> Void
        var onPaste: ([ChatAttachment]) -> Void
        var observer: NSObjectProtocol?
        weak var textView: NSTextView?

        init(
            documentID: String,
            onEdit: @escaping (String) -> Void,
            onSubmit: @escaping () -> Void,
            onPaste: @escaping ([ChatAttachment]) -> Void
        ) {
            self.documentID = documentID
            self.onEdit = onEdit
            self.onSubmit = onSubmit
            self.onPaste = onPaste
            super.init()
            // The composer is cleared by the view that owns the draft, which has
            // no reference to this text view.
            observer = NotificationCenter.default.addObserver(
                forName: .chatComposerShouldClear,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.textView?.string = ""
                }
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onEdit(textView.string)
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            // Shift+Enter arrives as insertNewlineIgnoringFieldEditor, so plain
            // insertNewline here always means "send".
            onSubmit()
            return true
        }
    }

    /// Assembled by hand rather than via `NSTextView.scrollableTextView()`, which
    /// hardcodes a plain NSTextView and leaves no way to install the paste-aware
    /// subclass.
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = PasteAwareTextView()
        textView.onPasteImages = { [coordinator = context.coordinator] attachments in
            coordinator.onPaste(attachments)
        }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 2, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onEdit = onEdit
        coordinator.onSubmit = onSubmit
        coordinator.onPaste = onPasteImages
        guard coordinator.documentID != documentID else { return }
        coordinator.documentID = documentID
        (scrollView.documentView as? NSTextView)?.string = ""
    }
}

/// Intercepts image pastes. Without this, pasting a screenshot into a plain-text
/// view either drops it silently or inserts a placeholder character.
final class PasteAwareTextView: NSTextView {
    var onPasteImages: (([ChatAttachment]) -> Void)?

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let attachments = urls.compactMap { try? ChatImageLoader.attachment(fromFile: $0) }
            if !attachments.isEmpty {
                onPasteImages?(attachments)
                return
            }
        }

        if let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           !images.isEmpty {
            let attachments = images.compactMap {
                ChatImageLoader.attachment(from: $0, name: "Вставка")
            }
            if !attachments.isEmpty {
                onPasteImages?(attachments)
                return
            }
        }

        super.pasteAsPlainText(sender)
    }
}
