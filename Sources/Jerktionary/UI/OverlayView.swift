import SwiftUI

/// Compact always-on-top mode: only the latest answer, sized for a screen
/// corner during a call. Ctrl+Shift+O (or the button) returns to full window.
struct OverlayView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(store.isListening ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(store.isListening ? "слушаю" : "пауза")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("· Ctrl+Shift+Space — ответить сейчас")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    store.toggleOverlay()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Выйти из компактного режима (Ctrl+Shift+O)")
            }

            if let question = store.answeredQuestions.first {
                ScrollView {
                    AnswerCardView(question: question, latest: true)
                }
                .scrollContentBackground(.hidden)
            } else {
                VStack {
                    Label("Ответ на последний вопрос появится здесь", systemImage: "sparkles")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .journalPromptCard()
            }
        }
        .padding(10)
        .background(Theme.canvas)
    }
}
