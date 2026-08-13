import Foundation

/// Meeting archive stored as JSON at ~/Library/Application Support/Jerktionary/meetings.json —
/// the same file and shape the Electron app uses, so history carries over.
@MainActor
final class MeetingsStore: ObservableObject {
    static let maxMeetings = 100

    @Published private(set) var meetings: [MeetingRecord] = []

    private let ioQueue = DispatchQueue(label: "com.jerktionary.meetings.io", qos: .utility)
    private var loadRequested = false
    private var loadFinished = false
    private var mutatedDuringLoad = false
    private var deletedDuringLoad: Set<String> = []

    private var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jerktionary", isDirectory: true)
            .appendingPathComponent("meetings.json")
    }

    init() {
        load()
    }

    func load() {
        guard !loadRequested else { return }
        loadRequested = true
        let url = storeURL
        ioQueue.async { [weak self] in
            let parsed: [MeetingRecord]
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([MeetingRecord].self, from: data) {
                parsed = decoded
            } else {
                parsed = []
            }
            DispatchQueue.main.async {
                self?.finishLoading(parsed)
            }
        }
    }

    private func finishLoading(_ persisted: [MeetingRecord]) {
        var merged = persisted.filter { !deletedDuringLoad.contains($0.id) }
        for current in meetings {
            if let index = merged.firstIndex(where: { $0.id == current.id }) {
                merged[index] = current
            } else {
                merged.append(current)
            }
        }
        meetings = Array(merged.sorted { $0.startedAt > $1.startedAt }.prefix(Self.maxMeetings))
        loadFinished = true
        if mutatedDuringLoad {
            persist()
        }
        mutatedDuringLoad = false
        deletedDuringLoad = []
    }

    private func markMutation(deleting id: String? = nil) {
        guard !loadFinished else { return }
        mutatedDuringLoad = true
        if let id { deletedDuringLoad.insert(id) }
    }

    func save(_ record: MeetingRecord) {
        markMutation()
        var next = meetings.filter { $0.id != record.id }
        next.insert(record, at: 0)
        meetings = Array(next.prefix(Self.maxMeetings))
        persist()
    }

    func delete(_ id: String) {
        markMutation(deleting: id)
        meetings.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard loadFinished else {
            mutatedDuringLoad = true
            return
        }
        let snapshot = meetings
        let url = storeURL
        ioQueue.async {
            do {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted]
                try encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                // Losing history is better than breaking the app.
                NSLog("Jerktionary: failed to persist meetings: \(error)")
            }
        }
    }

    func flushPendingWrites() {
        ioQueue.sync {}
    }

    // MARK: Export

    static func formatDate(_ millis: Double) -> String {
        NotesStore.formatDate(millis)
    }

    static func markdown(for record: MeetingRecord) -> String {
        var lines = ["# Встреча \(formatDate(record.startedAt))", ""]
        if !record.context.isEmpty {
            lines += ["**Контекст:** \(record.context)", ""]
        }
        if !record.qa.isEmpty {
            lines += ["## Вопросы и ответы", ""]
            for (index, item) in record.qa.enumerated() {
                lines += ["### \(index + 1). \(item.question)", ""]
                if !item.answer.isEmpty {
                    lines += [item.answer, ""]
                }
                if !item.points.isEmpty {
                    lines += item.points.map { "- \($0)" } + [""]
                }
                if !item.example.isEmpty {
                    lines += ["Пример: \(item.example)", ""]
                }
            }
        }
        if !record.transcript.isEmpty {
            lines += ["## Транскрипт", "", record.transcript, ""]
        }
        return lines.joined(separator: "\n")
    }
}
