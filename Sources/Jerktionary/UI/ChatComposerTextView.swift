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
    let onHeightChange: (CGFloat) -> Void
    let onSubmit: () -> Void
    let onPasteImages: ([ChatAttachment]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            documentID: documentID,
            onEdit: onEdit,
            onHeightChange: onHeightChange,
            onSubmit: onSubmit,
            onPaste: onPasteImages
        )
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var documentID: String
        var onEdit: (String) -> Void
        var onHeightChange: (CGFloat) -> Void
        var onSubmit: () -> Void
        var onPaste: ([ChatAttachment]) -> Void
        var observer: NSObjectProtocol?
        weak var textView: NSTextView?
        private var lastReportedHeight: CGFloat = 0

        init(
            documentID: String,
            onEdit: @escaping (String) -> Void,
            onHeightChange: @escaping (CGFloat) -> Void,
            onSubmit: @escaping () -> Void,
            onPaste: @escaping ([ChatAttachment]) -> Void
        ) {
            self.documentID = documentID
            self.onEdit = onEdit
            self.onHeightChange = onHeightChange
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
                    self?.reportHeight()
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
            reportHeight()
        }

        func reportHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer
            else { return }
            layoutManager.ensureLayout(for: textContainer)
            let contentHeight = ceil(
                layoutManager.usedRect(for: textContainer).height
                    + textView.textContainerInset.height * 2
            )
            guard abs(contentHeight - lastReportedHeight) >= 0.5 else { return }
            lastReportedHeight = contentHeight
            onHeightChange(contentHeight)
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            // Shift+Enter and Enter both arrive as insertNewline: — the modifier
            // is only visible on the event, so it has to be read from there.
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    return false // let the text view break the line
                }
                onSubmit()
                return true
            }
            // Some layouts and input sources send this one for Shift+Return.
            if selector == #selector(NSResponder.insertLineBreak(_:))
                || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            }
            return false
        }
    }

    /// Assembled by hand rather than via `NSTextView.scrollableTextView()`, which
    /// hardcodes a plain NSTextView and leaves no way to install the paste-aware
    /// subclass.
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ComposerScrollView()
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
        textView.placeholder = "Сообщение…"
        textView.setAccessibilityLabel("Сообщение")
        textView.setAccessibilityPlaceholderValue("Сообщение…")
        textView.setAccessibilityHelp("Enter — отправить, Shift+Enter — перенос строки")
        // With a 34pt single-line field, 8pt centers the system font and caret
        // on the same horizontal axis as the two 30pt action buttons.
        textView.textContainerInset = NSSize(width: 2, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        scrollView.onLayout = { [coordinator = context.coordinator] in
            // AppKit may lay out while SwiftUI is updating this representable;
            // defer the scalar state change to the next main-loop turn.
            DispatchQueue.main.async {
                coordinator.reportHeight()
            }
        }
        context.coordinator.textView = textView
        DispatchQueue.main.async { [coordinator = context.coordinator] in
            coordinator.reportHeight()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onEdit = onEdit
        coordinator.onHeightChange = onHeightChange
        coordinator.onSubmit = onSubmit
        coordinator.onPaste = onPasteImages
        guard coordinator.documentID != documentID else { return }
        coordinator.documentID = documentID
        (scrollView.documentView as? NSTextView)?.string = ""
    }
}

/// Notifies the representable when its width changes so wrapping can update the
/// composer's height without putting the whole draft into SwiftUI state.
private final class ComposerScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// Intercepts image pastes. Without this, pasting a screenshot into a plain-text
/// view either drops it silently or inserts a placeholder character.
final class PasteAwareTextView: NSTextView {
    var onPasteImages: (([ChatAttachment]) -> Void)?
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty,
              window?.firstResponder !== self,
              !placeholder.isEmpty
        else { return }

        let linePadding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(
            x: textContainerInset.width + linePadding,
            y: textContainerInset.height
        )
        placeholder.draw(
            at: origin,
            withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

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
