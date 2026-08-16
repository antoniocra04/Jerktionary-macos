import AppKit
import SwiftUI

/// The only entry point into live-answer generation. Transcript changes never
/// call the answer manager; the user freezes a request with this control.
struct AnswerRequestBar: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var answers: AnswerStreamManager

    var compact = false
    @State private var editing = false
    @State private var draft = ""

    private var hasTranscript: Bool {
        TranscriptExcerpt.latest(in: store.currentText) != nil
    }

    private var canGenerate: Bool {
        hasTranscript && store.backendReady && !store.backendUnavailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editing {
                HStack(spacing: 8) {
                    TextField("What do you need a hint about?", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submitDraft)

                    Button(action: submitDraft) {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Answer")
                    .accessibilityLabel("Answer the request you typed")

                    Button {
                        editing = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel editing")
                    .accessibilityLabel("Cancel editing")
                }
            } else {
                HStack(spacing: 8) {
                    if answers.isGenerating {
                        Button {
                            store.cancelAnswer()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(.red)
                    } else {
                        Button {
                            store.answerNow()
                        } label: {
                            Label(compact ? "Answer" : "Answer now", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .disabled(!canGenerate)
                        .help(answerButtonHelp)
                    }

                    Menu {
                        Button("Refine the request…", systemImage: "pencil") {
                            draft = TranscriptExcerpt.latest(in: store.currentText) ?? ""
                            editing = true
                        }
                        Button("Answer with full context", systemImage: "text.append") {
                            store.fullContextAnswer()
                        }
                        .disabled(!canGenerate)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Other ways to answer")
                    .accessibilityLabel("Other ways to answer")

                    if answers.isGenerating {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("An answer is being prepared")
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(compact ? 8 : 12)
        .background(
            Theme.tint.opacity(0.07),
            in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous)
        )
    }

    private func submitDraft() {
        let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        if store.requestAnswer(question: request) { editing = false }
    }

    private var answerButtonHelp: String {
        if !store.backendReady || store.backendUnavailable {
            return "The answer service is unavailable right now"
        }
        if !hasTranscript { return "Not enough speech yet to answer" }
        return "Freeze the last utterance and prepare an answer (Ctrl+Shift+Space)"
    }
}

/// One answer card at a time with arrow-key/chevron navigation through the
/// explicitly requested answer history.
struct LiveAnswersView: View {
    @EnvironmentObject private var store: AppStore
    @State private var navHead: String?
    @State private var navIndex = 0

    private var head: String? { store.answerRequests.first }
    private var total: Int { store.answerRequests.count }

    /// Derived: when a new question arrived (head changed), show the newest.
    private var index: Int {
        navHead == head ? min(navIndex, max(0, total - 1)) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if total == 0 {
                emptyState
            } else {
                AnswerCardView(question: store.answerRequests[index])
                    .id(store.answerRequests[index])

                if total > 1 {
                    pager
                }
            }
        }
        .background(ArrowKeyMonitor(
            // The session area stays mounted while the Notes tab is shown, so
            // only arm the arrow monitor when the session is actually visible.
            enabled: total > 1 && store.mainTab == .session,
            onOlder: { move(+1) },
            onNewer: { move(-1) }
        ))
    }

    private func move(_ delta: Int) {
        let current = index
        navHead = head
        navIndex = max(0, min(current + delta, total - 1))
    }

    private var pager: some View {
        HStack {
            Text(index == 0 ? "Latest answer" : "\(total - index) of \(total)")
            Spacer()
            Button {
                move(+1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(index >= total - 1)
            .help("Older answer")
            .accessibilityLabel("Older answer")
            Button {
                move(-1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(index <= 0)
            .help("Newer answer")
            .accessibilityLabel("Newer answer")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("When you need a hint, press “Answer now”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .journalPromptCard(padding: 20)
    }
}

/// Global-ish arrow-key handling: a local NSEvent monitor that skips events
/// while a text field/editor is first responder — the SwiftUI counterpart of
/// the window keydown listener in the Electron app.
private struct ArrowKeyMonitor: NSViewRepresentable {
    let enabled: Bool
    let onOlder: () -> Void
    let onNewer: () -> Void

    final class Coordinator {
        var keyMonitor: Any?
        var clickMonitor: Any?
        var onOlder: () -> Void = {}
        var onNewer: () -> Void = {}
        var enabled = false

        deinit {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            if let clickMonitor {
                NSEvent.removeMonitor(clickMonitor)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let coordinator = context.coordinator
        coordinator.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard coordinator.enabled else { return event }
            // Don't steal arrows from text inputs (field editor is an NSTextView).
            if event.window?.firstResponder is NSTextView || event.window?.firstResponder is NSTextField {
                return event
            }
            switch event.keyCode {
            case 123, 125: // left, down → older
                coordinator.onOlder()
                return nil
            case 124, 126: // right, up → newer
                coordinator.onNewer()
                return nil
            default:
                return event
            }
        }
        // Unlike the browser, macOS keeps a TextField focused after a click
        // elsewhere, so arrows would stay captured by the field forever.
        // Blur on any click that isn't inside a text view — matches web UX.
        coordinator.clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let window = event.window,
                  window.firstResponder is NSTextView || window.firstResponder is NSTextField
            else { return event }
            let point = event.locationInWindow
            let hit = window.contentView?.hitTest(point)
            var view: NSView? = hit
            while let current = view {
                if current is NSTextView || current is NSTextField {
                    return event // clicked into a text input — keep focus
                }
                view = current.superview
            }
            window.makeFirstResponder(nil)
            return event
        }
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.onOlder = onOlder
        context.coordinator.onNewer = onNewer
    }
}

struct AnswerCardView: View {
    @EnvironmentObject private var store: AppStore
    /// Observed directly: the streamed answer lives on this object, and reading
    /// it through AppStore would not subscribe the card to its updates.
    @EnvironmentObject private var answers: AnswerStreamManager
    let question: String
    /// In the overlay the panel is already the card; drawing another one inside
    /// it nests two surfaces and spends 26pt a side of a 520pt window.
    var compact = false
    @State private var deep = false
    @State private var copied = false

    var body: some View {
        let state = answers.state(question: question, deep: deep)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(question)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 2 : 1)
                    .help(question)
                Spacer()
                if state.streaming {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("typing")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            if let error = state.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                Button {
                    answers.regenerate(question: question, deep: deep, context: store.currentText)
                } label: {
                    Label("Try again", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else if let answer = state.answer {
                if !answer.answer.isEmpty {
                    Text(answer.answer)
                        .font(compact ? .title3 : .system(size: 16))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
                if !answer.points.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(answer.points, id: \.self) { point in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 7)
                                Text(point)
                            }
                            .font(compact ? .body : .callout)
                        }
                    }
                }
                if !answer.example.isEmpty {
                    Text(answer.example)
                        .font(.callout.italic())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            .quaternary.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                }

                ViewThatFits(in: .horizontal) {
                    fullAnswerActions(answer: answer, streaming: state.streaming)
                    compactAnswerActions(answer: answer, streaming: state.streaming)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing the answer…")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .padding(compact ? 0 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            compact ? AnyShapeStyle(.clear) : AnyShapeStyle(Theme.card),
            in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        )
        .shadow(color: compact ? .clear : Theme.shadowColor, radius: 6, y: 1)
    }

    private func copy(_ answer: LiveAnswer) {
        let text = ([answer.answer] + answer.points.map { "— \($0)" } + [answer.example])
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        AccessibilityAnnouncer.announce("Answer copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }

    private func fullAnswerActions(answer: LiveAnswer, streaming: Bool) -> some View {
        HStack(spacing: 16) {
            depthButton
            copyButton(answer)
            if !streaming {
                regenerateButton
            }
        }
    }

    private func compactAnswerActions(answer: LiveAnswer, streaming: Bool) -> some View {
        HStack(spacing: 10) {
            depthButton
            Spacer(minLength: 0)
            Menu {
                copyButton(answer)
                if !streaming {
                    regenerateButton
                }
            } label: {
                Label("Answer actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var depthButton: some View {
        Button(deep ? "Shorter" : "More detail") {
            deep.toggle()
            if deep {
                let started = answers.ensureStream(
                    question: question,
                    deep: true,
                    context: store.currentText
                )
                if !started, answers.state(question: question, deep: true).answer == nil {
                    deep = false
                    store.showNotice("An answer is already being prepared")
                }
            }
        }
    }

    private func copyButton(_ answer: LiveAnswer) -> some View {
        Button {
            copy(answer)
        } label: {
            Label(copied ? "Copied" : "Copy",
                  systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }

    private var regenerateButton: some View {
        Button {
            answers.regenerate(question: question, deep: deep, context: store.currentText)
        } label: {
            Label("Regenerate", systemImage: "arrow.counterclockwise")
        }
    }
}

/// Free-form pre-meeting context, sent with every answer request — styled as
/// a Journal reflection prompt.
struct MeetingContextField: View {
    @EnvironmentObject private var store: AppStore
    var compact = false

    @ViewBuilder
    var body: some View {
        if compact {
            fields
                .padding(10)
                .background(
                    Theme.card.opacity(0.72),
                    in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous)
                )
        } else {
            fields.journalPromptCard(padding: 14)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            if !compact {
                Text("Meeting context")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tint)
            }
            TextField(
                compact ? "Meeting context" : "Role, company, or topic of the conversation",
                text: $store.meetingContext,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.callout)
            .lineLimit(compact ? 1...2 : 2...4)
        }
    }
}
