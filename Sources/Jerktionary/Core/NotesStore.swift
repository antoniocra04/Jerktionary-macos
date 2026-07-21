import Foundation

/// The main working area's active tab.
enum MainTab: String, CaseIterable, Identifiable {
    case session
    case notes
    var id: String { rawValue }
}

/// A free-form note, persisted independently of meetings.
struct Note: Codable, Identifiable, Hashable {
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

    /// First non-empty line as a display title, falling back to a placeholder.
    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        let firstLine = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return firstLine.isEmpty ? "Новая заметка" : firstLine
    }
}

/// Notes archive stored as JSON next to meetings.json in Application Support.
@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [Note] = []

    private var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jerktionary", isDirectory: true)
            .appendingPathComponent("notes.json")
    }

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let parsed = try? JSONDecoder().decode([Note].self, from: data)
        else {
            notes = []
            return
        }
        notes = parsed.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Creates an empty note at the top and returns it for immediate editing.
    @discardableResult
    func create() -> Note {
        let note = Note.new()
        notes.insert(note, at: 0)
        persist()
        return note
    }

    func update(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var updated = note
        updated.updatedAt = Date.now.timeIntervalSince1970 * 1000
        notes[index] = updated
        // Keep the most-recently-edited note on top.
        notes.sort { $0.updatedAt > $1.updatedAt }
        persist()
    }

    func delete(_ id: String) {
        notes.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        do {
            let directory = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(notes).write(to: storeURL)
        } catch {
            NSLog("Jerktionary: failed to persist notes: \(error)")
        }
    }

    static func formatDate(_ millis: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy, HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: millis / 1000))
    }
}
