import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let meeting: MeetingRecord
    var onClose: (() -> Void)?
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(MeetingsStore.formatDate(meeting.startedAt))
                        .font(.title3.weight(.bold))
                    Spacer()
                    CircleToolbarButton(systemImage: "square.and.arrow.up", help: "Экспорт в Markdown") {
                        exportMarkdown()
                    }
                    CircleToolbarButton(systemImage: "trash", help: "Удалить встречу") {
                        confirmingDelete = true
                    }
                    CircleToolbarButton(systemImage: "xmark", help: "Закрыть") {
                        (onClose ?? { dismiss() })()
                    }
                }

                if !meeting.context.isEmpty {
                    LabeledBlock(label: "Контекст", text: meeting.context)
                        .journalPromptCard(padding: 12)
                }

                if !meeting.qa.isEmpty {
                    Text("Вопросы и ответы")
                        .font(.headline)
                    ForEach(Array(meeting.qa.enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(index + 1). \(item.question)")
                                .font(.subheadline.weight(.semibold))
                            if !item.answer.isEmpty {
                                Text(item.answer)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            ForEach(item.points, id: \.self) { point in
                                Text("• \(point)")
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !item.example.isEmpty {
                                LabeledBlock(label: "Пример", text: item.example)
                            }
                        }
                        .journalCard(padding: 12)
                    }
                }

                if !meeting.transcript.isEmpty {
                    Text("Транскрипт")
                        .font(.headline)
                    Text(meeting.transcript)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .journalCard(padding: 12)
                }
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
        .alert("Удалить встречу?", isPresented: $confirmingDelete) {
            Button("Удалить", role: .destructive) {
                store.meetings.delete(meeting.id)
                (onClose ?? { dismiss() })()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Транскрипт и ответы этой встречи нельзя будет восстановить.")
        }
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let stamp = MeetingsStore.formatDate(meeting.startedAt)
            .replacingOccurrences(of: "[.,: ]+", with: "-", options: .regularExpression)
        panel.nameFieldStringValue = "meeting-\(stamp).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? MeetingsStore.markdown(for: meeting).write(to: url, atomically: true, encoding: .utf8)
    }
}
