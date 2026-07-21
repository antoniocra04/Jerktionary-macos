import SwiftUI

/// Notes working area. A thin wrapper that hands the nested NotesStore to a
/// body that observes it directly — otherwise, since NotesView only watches
/// AppStore, changes to the nested store's notes wouldn't refresh the list.
struct NotesView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NotesBody(notesStore: store.notes)
    }
}

/// List of notes on the left, the editor on the right. Independent of the
/// listening pipeline — transcription and answers keep running here.
private struct NotesBody: View {
    @ObservedObject var notesStore: NotesStore
    @State private var selectedID: String?

    private var notes: [Note] { notesStore.notes }

    /// A binding straight to the note in the store, so the editor and the list
    /// share one source of truth — the title updates in the list as you type.
    private func binding(for id: String) -> Binding<Note>? {
        guard notesStore.notes.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { notesStore.notes.first { $0.id == id } ?? Note.new() },
            set: { notesStore.update($0) }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            noteList
                .frame(width: 260)

            Group {
                if let selectedID, let noteBinding = binding(for: selectedID) {
                    NoteEditor(note: noteBinding)
                        .id(selectedID)
                } else {
                    emptyEditor
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 28)
        .padding(.top, 4)
        .padding(.bottom, 28)
        .onAppear {
            notesStore.load()
            if selectedID == nil || !notes.contains(where: { $0.id == selectedID }) {
                selectedID = notes.first?.id
            }
        }
    }

    private var noteList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Заметки")
                    .font(.headline)
                Spacer()
                Button {
                    let note = notesStore.create()
                    selectedID = note.id
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tint)
                .help("Новая заметка")
            }

            if notes.isEmpty {
                Text("Заметок пока нет. Нажмите ✎, чтобы создать.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(notes) { note in
                            NoteRow(note: note, selected: note.id == selectedID) {
                                selectedID = note.id
                            } onDelete: {
                                notesStore.delete(note.id)
                                if selectedID == note.id {
                                    selectedID = notesStore.notes.first?.id
                                }
                            }
                        }
                    }
                    // Animate the move-to-top reorder when a note is edited.
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: notes.map(\.id))
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var emptyEditor: some View {
        VStack(spacing: 10) {
            Image(systemName: "note.text")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.lavenderGradient)
            Text("Выберите заметку или создайте новую")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One row in the notes list.
private struct NoteRow: View {
    let note: Note
    let selected: Bool
    let open: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(NotesStore.formatDate(note.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Theme.tint.opacity(0.14) : (hovering ? Theme.tint.opacity(0.07) : .clear),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Удалить", role: .destructive, action: onDelete)
        }
    }
}

/// Title + body editor bound directly to the store's note — a single source of
/// truth, so edits always land on the right note and the list reflects them live.
/// The body supports Markdown via an edit/preview toggle.
private struct NoteEditor: View {
    @Binding var note: Note
    @State private var preview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Заголовок", text: $note.title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.bold))

                Picker("", selection: $preview) {
                    Image(systemName: "pencil").tag(false)
                    Image(systemName: "eye").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(preview ? "Редактировать" : "Просмотр Markdown")
            }

            Divider()

            if preview {
                ScrollView {
                    Group {
                        if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Пусто. Переключитесь в режим ✎, чтобы писать. Поддерживается Markdown.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            MarkdownView(text: note.body)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TextEditor(text: $note.body)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Text("Markdown")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Изменено \(NotesStore.formatDate(note.updatedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .journalCard(padding: 18)
    }
}
