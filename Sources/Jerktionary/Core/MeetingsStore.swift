import Foundation

/// Meeting archive stored as JSON at ~/Library/Application Support/Jerktionary/meetings.json —
/// the same file and shape the Electron app uses, so history carries over.
@MainActor
final class MeetingsStore: ObservableObject {
    static let maxMeetings = 100

    @Published private(set) var meetings: [MeetingRecord] = []

    private var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jerktionary", isDirectory: true)
            .appendingPathComponent("meetings.json")
    }

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let parsed = try? JSONDecoder().decode([MeetingRecord].self, from: data)
        else {
            meetings = []
            return
        }
        meetings = parsed
    }

    func save(_ record: MeetingRecord) {
        var next = meetings.filter { $0.id != record.id }
        next.insert(record, at: 0)
        meetings = Array(next.prefix(Self.maxMeetings))
        persist()
    }

    func delete(_ id: String) {
        meetings.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        do {
            let directory = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(meetings).write(to: storeURL)
        } catch {
            // Losing history is better than breaking the app.
            NSLog("Jerktionary: failed to persist meetings: \(error)")
        }
    }

    // MARK: Export

    static func formatDate(_ millis: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy, HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: millis / 1000))
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
