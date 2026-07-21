import AppKit
import SwiftUI

/// One answer card at a time with arrow-key/chevron navigation through the
/// question history — mirrors the Electron LiveAnswer pager: a new question
/// snaps back to the latest answer, otherwise the chosen position is kept.
struct LiveAnswersView: View {
    @EnvironmentObject private var store: AppStore
    @State private var navHead: String?
    @State private var navIndex = 0

    private var head: String? { store.answeredQuestions.first }
    private var total: Int { store.answeredQuestions.count }

    /// Derived: when a new question arrived (head changed), show the newest.
    private var index: Int {
        navHead == head ? min(navIndex, max(0, total - 1)) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if total == 0 {
                emptyState
            } else {
                AnswerCardView(question: store.answeredQuestions[index], latest: index == 0)
                    .id(store.answeredQuestions[index])

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
            Text(index == 0 ? "последний вопрос" : "\(total - index) из \(total)")
            Spacer()
            Text("← → переключение")
                .foregroundStyle(.tertiary)
            Button {
                move(+1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(index >= total - 1)
            .help("Более старый вопрос")
            Button {
                move(-1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(index <= 0)
            .help("Более новый вопрос")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Живой ответ", systemImage: "sparkles")
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.tint)
            Text("Задайте вопрос вслух — «что такое…», «как…», «почему…» — и ответ для проговаривания появится здесь. Прошлые ответы переключаются стрелками, Ctrl+Shift+Space отвечает на последнюю фразу.")
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
    let question: String
    var latest = false
    @State private var deep = false
    @State private var copied = false

    var body: some View {
        let state = store.answers.state(question: question, deep: deep)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(question)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if state.streaming {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("печатается")
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
                    store.answers.regenerate(question: question, deep: deep, context: store.currentText)
                } label: {
                    Label("Попробовать ещё раз", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else if let answer = state.answer {
                if !answer.answer.isEmpty {
                    Text(answer.answer)
                        .font(.system(size: 16))
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
                            .font(.callout)
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

                HStack(spacing: 16) {
                    Button(deep ? "Короче" : "Подробнее") {
                        deep.toggle()
                        if deep {
                            store.answers.ensureStream(question: question, deep: true, context: store.currentText)
                        }
                    }
                    Button {
                        copy(answer)
                    } label: {
                        Label(copied ? "Скопировано" : "Копировать",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    if !state.streaming {
                        Button {
                            store.answers.regenerate(question: question, deep: deep, context: store.currentText)
                        } label: {
                            Label("Перегенерировать", systemImage: "arrow.counterclockwise")
                        }
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Готовлю ответ…")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .journalCard()
    }

    private func copy(_ answer: LiveAnswer) {
        let text = ([answer.answer] + answer.points.map { "— \($0)" } + [answer.example])
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}

/// Free-form pre-meeting context, sent with every answer request — styled as
/// a Journal reflection prompt.
struct MeetingContextField: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Контекст встречи")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tint)
            TextField(
                "Вакансия, компания, тема разговора — подсказки для ответов",
                text: $store.meetingContext,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.callout)
            .lineLimit(2...4)
        }
        .journalPromptCard(padding: 14)
    }
}
