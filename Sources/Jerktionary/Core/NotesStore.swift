import Foundation

/// The main working area's active tab.
enum MainTab: String, CaseIterable, Identifiable {
    case session
    case notes
    case chat
    var id: String { rawValue }
}

/// A free-form note, persisted independently of meetings.
struct Note: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var body: String
    var createdAt: Double
    var updatedAt: Double

    static func new() -> Note {
        let now = Date.now.timeIntervalSince1970 * 1000
        return Note(
            id: "\(Int(now))-\(String(UUID().uuidString.prefix(6)).lowercased())",
            title: "",
            body: "",
            createdAt: now,
            updatedAt: now
        )
    }

    /// How far into the body to look for a title line, and how long the result
    /// may get. Both are bounds against pasted text: this runs for every visible
    /// row on every list rebuild, and splitting a few hundred KB of body — then
    /// handing the result to a single-line `Text` — cost milliseconds per row.
    static let titleScanLimit = 200
    static let titleLengthLimit = 80

    /// First non-empty line as a display title, falling back to a placeholder.
    /// Only the first `titleScanLimit` characters are considered, so a note that
    /// opens with more blank space than that shows the placeholder instead.
    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(title.prefix(Self.titleLengthLimit))
        }
        let firstLine = body
            .prefix(Self.titleScanLimit)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return firstLine.isEmpty ? "Новая заметка" : String(firstLine.prefix(Self.titleLengthLimit))
    }
}

/// Notes archive stored as JSON next to meetings.json in Application Support.
@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [Note] = []

    /// Writes are debounced and run off the main thread: `update` is called as
    /// the user types, and encoding the whole archive on every edit stalled input.
    private static let persistDebounceNanos: UInt64 = 400_000_000
    private let ioQueue = DispatchQueue(label: "com.jerktionary.notes.io", qos: .utility)
    private var persistTask: Task<Void, Never>?
    private var loadRequested = false
    private var loadFinished = false
    private var mutatedDuringLoad = false
    private var deletedDuringLoad: Set<String> = []

    private var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jerktionary", isDirectory: true)
            .appendingPathComponent("notes.json")
    }

    init() {
        load()
    }

    func load() {
        guard !loadRequested else { return }
        loadRequested = true
        let url = storeURL
        ioQueue.async { [weak self] in
            let parsed: [Note]
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([Note].self, from: data) {
                parsed = decoded
            } else {
                parsed = []
            }
            DispatchQueue.main.async {
                self?.finishLoading(parsed)
            }
        }
    }

    private func finishLoading(_ persisted: [Note]) {
        var merged = persisted.filter { !deletedDuringLoad.contains($0.id) }
        for current in notes {
            if let index = merged.firstIndex(where: { $0.id == current.id }) {
                merged[index] = current
            } else {
                merged.append(current)
            }
        }
        notes = merged.sorted { $0.updatedAt > $1.updatedAt }
        loadFinished = true
        if mutatedDuringLoad {
            persistNow()
        }
        mutatedDuringLoad = false
        deletedDuringLoad = []
    }

    private func markMutation(deleting id: String? = nil) {
        guard !loadFinished else { return }
        mutatedDuringLoad = true
        if let id { deletedDuringLoad.insert(id) }
    }

    func note(id: String) -> Note? {
        notes.first { $0.id == id }
    }

    /// Creates an empty note at the top and returns it for immediate editing.
    @discardableResult
    func create() -> Note {
        markMutation()
        let note = Note.new()
        notes.insert(note, at: 0)
        persistNow()
        return note
    }

    /// Bumps the edited time and re-sorts so the note moves to the top (Apple
    /// Notes style). Safe to sort now that editing is keyed by note id, not by
    /// list position — the selection can't desync onto the wrong note.
    func update(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        let existing = notes[index]
        // Only an actual content change reorders. Focusing a field writes back
        // the same value; without this guard the note would jump to the top on
        // focus alone, before any editing.
        guard existing.title != note.title || existing.body != note.body else { return }
        markMutation()
        var updated = note
        updated.updatedAt = Date.now.timeIntervalSince1970 * 1000
        notes[index] = updated
        notes.sort { $0.updatedAt > $1.updatedAt }
        schedulePersist()
    }

    func delete(_ id: String) {
        markMutation(deleting: id)
        notes.removeAll { $0.id == id }
        persistNow()
    }

    /// Commits any debounced write and blocks until it has reached the disk.
    /// Call before the app quits or loses focus — nothing else waits for the
    /// background write, so this is the only guarantee that edits survive.
    func flushPendingWrites() {
        if persistTask != nil {
            persistNow()
        }
        ioQueue.sync {}
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.persistDebounceNanos)
            guard !Task.isCancelled, let self else { return }
            self.persistNow()
        }
    }

    private func persistNow() {
        guard loadFinished else {
            mutatedDuringLoad = true
            return
        }
        persistTask?.cancel()
        persistTask = nil
        // The serial queue keeps writes ordered, so the newest snapshot wins.
        let snapshot = notes
        let url = storeURL
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted]
                try encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                NSLog("Jerktionary: failed to persist notes: \(error)")
            }
        }
    }

    static func formatDate(_ millis: Double) -> String {
        dateFormatter.string(from: Date(timeIntervalSince1970: millis / 1000))
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy, HH:mm"
        return formatter
    }()
}
