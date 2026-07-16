import SwiftUI

/// Live transcript with tappable highlighted terms.
struct TranscriptView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedTerm: TranscriptTerm?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Транскрипт")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            if store.currentText.isEmpty {
                Text(store.isListening
                     ? "Слушаю… говорите, транскрипт появится здесь."
                     : "Нажмите «Слушать», чтобы начать транскрипцию.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
                    .journalCard()
            } else {
                highlightedText
                    .journalCard()
                    .popover(item: $selectedTerm) { term in
                        TermExplanationPopover(term: term)
                    }
            }
        }
    }

    /// Terms are rendered as underline+tint runs inside one Text; taps resolve
    /// via an invisible layout of segment views is overkill — use a flow of
    /// Texts with tap gestures per segment instead.
    private var highlightedText: some View {
        let segments = TermMerger.highlightSegments(text: store.currentText, terms: store.terms)
        // AttributedString supports links; use a custom scheme to catch term taps.
        var attributed = AttributedString()
        for segment in segments {
            switch segment {
            case .text(let text, _):
                attributed += AttributedString(text)
            case .term(let text, let term):
                var run = AttributedString(text)
                run.foregroundColor = .accentColor
                run.underlineStyle = .single
                if let url = URL(string: "jerktionary-term://\(term.id.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? "")") {
                    run.link = url
                }
                attributed += run
            }
        }
        return Text(attributed)
            .font(.body)
            .lineSpacing(4)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "jerktionary-term",
                      let host = url.host?.removingPercentEncoding,
                      let term = store.terms.first(where: { $0.id == host })
                else { return .discarded }
                selectedTerm = term
                store.explanations.fetchStreaming(term: term.normalized, context: store.currentText)
                return .handled
            })
    }
}

struct TermExplanationPopover: View {
    @EnvironmentObject private var store: AppStore
    let term: TranscriptTerm

    var body: some View {
        let state = store.explanations.state(term: term.normalized)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(state.explanation?.title.isEmpty == false ? state.explanation!.title : term.text)
                    .font(.headline)
                if state.loading {
                    ProgressView().controlSize(.small)
                }
                if let source = state.explanation?.source {
                    Text(sourceLabel(source))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            if let explanation = state.explanation {
                if !explanation.short.isEmpty {
                    Text(explanation.short)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !explanation.example.isEmpty {
                    LabeledBlock(label: "Пример", text: explanation.example)
                }
                if !explanation.whyImportant.isEmpty {
                    LabeledBlock(label: "Почему важно", text: explanation.whyImportant)
                }
            } else if let error = state.error {
                Text(error).foregroundStyle(.red)
            } else if !state.loading {
                Text("Объяснение появится здесь").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .onAppear {
            store.explanations.fetchStreaming(term: term.normalized, context: store.currentText)
        }
    }

    private func sourceLabel(_ source: ExplanationSource) -> String {
        switch source {
        case .cache: "кэш"
        case .localLLM: "локальная модель"
        case .apiLLM: "API"
        }
    }
}

struct LabeledBlock: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                // Without this, Text inside a popover truncates to one line
                // instead of wrapping.
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
