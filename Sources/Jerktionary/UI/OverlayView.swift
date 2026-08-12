import AppKit
import SwiftUI

/// Compact translucent card that floats over everything during a call.
///
/// Hosted in a floating panel with no title bar and a cleared background (see
/// OverlayPanel), so this view draws the whole card: the material, the rounded
/// edge, and the drag handle that replaces the title bar.
struct OverlayView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var chats: ChatStore

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().opacity(0.5)
            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .ignoresSafeArea()
        .onChange(of: settings.overlayOpacity) {
            OverlayPanel.shared.setOpacity(settings.overlayOpacity)
        }
    }

    // MARK: Title bar

    private var titleBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.isListening ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)

            Picker("", selection: paneBinding) {
                ForEach(OverlayPane.allCases) { pane in
                    Text(pane.russianLabel).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

            Spacer(minLength: 4)

            OpacityControl(opacity: $settings.overlayOpacity)

            Button {
                store.toggleOverlay()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Обычный режим (Ctrl+Shift+O)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // The window is movable by its background, but controls swallow drags —
        // this keeps the empty part of the bar behaving like a title bar.
        .contentShape(Rectangle())
    }

    // MARK: Panes

    @ViewBuilder
    private var pane: some View {
        switch settings.overlayPane {
        case .answer:
            answerPane
        case .chat:
            chatPane
        case .transcript:
            transcriptPane
        }
    }

    private var answerPane: some View {
        Group {
            if let question = store.answeredQuestions.first {
                ScrollView {
                    AnswerCardView(question: question, latest: true)
                        .padding(8)
                }
                .scrollContentBackground(.hidden)
            } else {
                hint("Ответ на последний вопрос появится здесь", icon: "sparkles")
            }
        }
    }

    private var chatPane: some View {
        Group {
            if let id = chats.selectedID, chats.conversation(id: id) != nil {
                ChatThreadView(conversationID: id, compact: true)
                    .id(id)
                    .padding(8)
            } else {
                VStack(spacing: 8) {
                    hint("Нет открытого чата", icon: "bubble.left.and.bubble.right")
                    Button("Новый чат") { chats.create() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
    }

    private var transcriptPane: some View {
        Group {
            if store.currentText.isEmpty {
                hint(
                    store.isListening
                        ? "Слушаю… транскрипт появится здесь"
                        : "Нажмите «Слушать», чтобы начать",
                    icon: "waveform"
                )
            } else {
                TranscriptTextView(
                    text: store.currentText,
                    terms: store.terms,
                    onTermTap: { _ in }
                )
                .padding(8)
            }
        }
    }

    private func hint(_ text: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }

    private var paneBinding: Binding<OverlayPane> {
        Binding(
            get: { settings.overlayPane },
            set: { settings.overlayPane = $0 }
        )
    }
}

/// Opacity slider that only unfolds on hover — at this size a permanent slider
/// would take most of the bar.
private struct OpacityControl: View {
    @Binding var opacity: Double
    @State private var expanded = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.lefthalf.filled")
                .font(.caption)
                .foregroundStyle(.secondary)
            if expanded {
                Slider(value: $opacity, in: 0.25...1)
                    .controlSize(.mini)
                    .frame(width: 80)
            }
        }
        .contentShape(Rectangle())
        .onHover { expanded = $0 }
        .help("Прозрачность")
    }
}
