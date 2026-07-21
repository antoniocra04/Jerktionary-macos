import SwiftUI

/// Notes working area: a list of notes on the left, the editor on the right.
/// Independent of the listening pipeline — transcription and answers keep
/// running while this tab is shown.
struct NotesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedID: String?

    private var notes: [Note] { store.notes.notes }

    private var selectedNote: Note? {
        notes.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            noteList
                .frame(width: 260)

            Group {
                if let note = selectedNote {
                    NoteEditor(note: note)
                        .id(note.id)
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
            store.notes.load()
            if selectedID == nil { selectedID = notes.first?.id }
        }
    }

    private var noteList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Заметки")
                    .font(.headline)
                Spacer()
                Button {
                    let note = store.notes.create()
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
                                store.notes.delete(note.id)
                                if selectedID == note.id {
                                    selectedID = store.notes.notes.first?.id
                                }
                            }
                        }
                    }
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

/// Title + body editor. Writes back to the store on every change (debounced by
/// the store, which just re-sorts and persists).
private struct NoteEditor: View {
    @EnvironmentObject private var store: AppStore
    let note: Note

    @State private var title: String = ""
    @State private var body_: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Заголовок", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.bold))
                .onChange(of: title) { _, _ in save() }

            Divider()

            TextEditor(text: $body_)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: body_) { _, _ in save() }

            HStack {
                Spacer()
                Text("Изменено \(NotesStore.formatDate(note.updatedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .journalCard(padding: 18)
        .onAppear {
            title = note.title
            body_ = note.body
        }
    }

    private func save() {
        var updated = note
        updated.title = title
        updated.body = body_
        store.notes.update(updated)
    }
}
