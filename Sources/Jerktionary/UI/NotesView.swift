import AppKit
import SwiftUI

/// List of notes on the left, the editor on the right. Independent of the
/// listening pipeline — transcription and answers keep running here.
///
/// Observes NotesStore directly instead of reaching through AppStore: both tabs
/// stay mounted, so an AppStore subscription meant every transcript and
/// microphone update re-rendered the whole editor behind the session view.
struct NotesView: View {
    @EnvironmentObject private var notesStore: NotesStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedID: String?

    private var notes: [Note] { notesStore.notes }

    var body: some View {
        HSplitView {
            noteList
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                .padding(.trailing, 8)

            Group {
                if let selectedID, let note = notesStore.note(id: selectedID) {
                    NoteEditor(noteID: selectedID, initialBody: note.body)
                        .id(selectedID)
                } else {
                    emptyEditor
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
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
                Text("Notes")
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
                .help("New note")
                .accessibilityLabel("New note")
            }

            if notes.isEmpty {
                Text("Create your first note.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
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
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.2),
                        value: notes.map(\.id)
                    )
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var emptyEditor: some View {
        VStack(spacing: 14) {
            Image(systemName: "note.text")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.lavenderGradient)
            Text("Pick a note or create a new one")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("New note", systemImage: "square.and.pencil") {
                let note = notesStore.create()
                selectedID = note.id
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
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
    @State private var confirmingDelete = false

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
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Delete", role: .destructive) {
                confirmingDelete = true
            }
        }
        .alert("Delete this note?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The note's text cannot be recovered.")
        }
    }
}

/// The in-progress body of the open note, held outside SwiftUI's state graph on
/// purpose: writing the whole document into `@State` or `@Published` on every
/// keystroke costs time proportional to its length. Mutating a plain reference
/// type doesn't invalidate anything, so typing does no SwiftUI work at all.
@MainActor
private final class NoteDraft {
    var text = ""
    var commitTask: Task<Void, Never>?
}

/// Title + body editor for one note, addressed by id so a commit always lands on
/// the right note no matter how the list has re-sorted underneath.
/// The body supports Markdown via an edit/preview toggle.
///
/// Edits land in `draft` as they happen and are committed to the store on a
/// short debounce — the store publish is what re-renders the list, so it must
/// not happen per keystroke. Every way out of the editor flushes first.
private struct NoteEditor: View {
    @EnvironmentObject private var notesStore: NotesStore
    let noteID: String

    @State private var draft: NoteDraft
    @State private var preview = false

    /// Long enough to coalesce a burst of typing, short enough that the title in
    /// the list and the move-to-top reorder still read as live.
    private static let commitDebounceNanos: UInt64 = 250_000_000

    /// The draft is seeded here rather than in `.task`, which would run after the
    /// text view had already been made with an empty document.
    init(noteID: String, initialBody: String) {
        self.noteID = noteID
        let draft = NoteDraft()
        draft.text = initialBody
        _draft = State(initialValue: draft)
    }

    private var note: Note? { notesStore.note(id: noteID) }

    /// The title is short, so it commits on every keystroke and keeps the list
    /// title live; only the body pays the debounce.
    private var titleBinding: Binding<String> {
        Binding(
            get: { notesStore.note(id: noteID)?.title ?? "" },
            set: { newValue in
                guard var current = notesStore.note(id: noteID), current.title != newValue else { return }
                current.title = newValue
                notesStore.update(current)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Title", text: titleBinding)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.bold))

                Picker("Note mode", selection: $preview) {
                    Label("Editing", systemImage: "pencil").tag(false)
                    Label("Preview", systemImage: "eye").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(preview ? "Edit" : "Preview Markdown")
            }

            Divider()

            if preview {
                ScrollView {
                    Group {
                        if draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("This note is empty.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            MarkdownView(text: draft.text)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                NoteTextEditor(
                    documentID: noteID,
                    initialText: draft.text,
                    onEdit: { text in
                        draft.text = text
                        scheduleCommit()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Spacer()
                Text("Edited \(NotesStore.formatDate(note?.updatedAt ?? 0))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .journalCard(padding: 18)
        // Every way the editor can stop being the thing you're typing into.
        .onDisappear { commit(flushToDisk: true) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            commit(flushToDisk: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            commit(flushToDisk: true)
        }
    }

    private func scheduleCommit() {
        draft.commitTask?.cancel()
        draft.commitTask = Task { [draft] in
            try? await Task.sleep(nanoseconds: Self.commitDebounceNanos)
            guard !Task.isCancelled else { return }
            draft.commitTask = nil
            commit()
        }
    }

    /// Re-reads the note instead of using a captured copy: the title commits on
    /// its own path, and the note may have been deleted while we were typing.
    private func commit(flushToDisk: Bool = false) {
        draft.commitTask?.cancel()
        draft.commitTask = nil
        if var current = notesStore.note(id: noteID), current.body != draft.text {
            current.body = draft.text
            notesStore.update(current)
        }
        if flushToDisk {
            notesStore.flushPendingWrites()
        }
    }
}
