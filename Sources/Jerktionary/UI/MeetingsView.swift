import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Meeting detail as an in-window modal: dimmed backdrop, click outside (or
/// Esc) closes — sheets can't do that natively on macOS.
struct MeetingModal: View {
    @EnvironmentObject private var store: AppStore
    let meeting: MeetingRecord

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { store.selectedMeeting = nil }

            MeetingDetailView(meeting: meeting, onClose: { store.selectedMeeting = nil })
                .frame(maxWidth: 640, maxHeight: 560)
                .background(
                    Theme.canvas,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .shadow(color: .black.opacity(0.25), radius: 28, y: 8)
                .padding(32)
                .onExitCommand { store.selectedMeeting = nil }
        }
    }
}

struct MeetingDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let meeting: MeetingRecord
    var onClose: (() -> Void)?

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
                        store.meetings.delete(meeting.id)
                        (onClose ?? { dismiss() })()
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
