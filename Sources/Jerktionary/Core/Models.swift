import Foundation

// MARK: - Terms

struct TranscriptTerm: Codable, Hashable, Identifiable {
    let text: String
    let normalized: String
    let start: Int
    let end: Int
    let type: String
    let confidence: Double

    var id: String { "\(normalized):\(start):\(end)" }
    var length: Int { end - start }
}

enum ExplanationSource: String, Codable {
    case cache
    case localLLM = "local_llm"
    case apiLLM = "api_llm"
}

struct TermExplanation: Equatable {
    var title: String
    var short: String
    var example: String
    var whyImportant: String
    var source: ExplanationSource
}

// MARK: - Answers

struct LiveAnswer: Equatable {
    var answer: String
    var points: [String]
    var example: String
}

// MARK: - WebSocket events

enum BackendWsEvent {
    case transcriptUpdate(text: String, isFinal: Bool, terms: [TranscriptTerm])
    case termsUpdate(items: [TranscriptTerm])
    case error(code: String)

    /// Mirrors the tolerant parser of the web client: unknown shapes are nil,
    /// malformed terms are dropped rather than failing the event.
    static func parse(_ data: Data) -> BackendWsEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let type = dict["type"] as? String
        else { return nil }

        switch type {
        case "transcript_update":
            guard let text = dict["text"] as? String else { return nil }
            return .transcriptUpdate(
                text: text,
                isFinal: dict["is_final"] as? Bool ?? false,
                terms: Self.parseTerms(dict["terms"])
            )
        case "terms_update":
            return .termsUpdate(items: Self.parseTerms(dict["items"]))
        case "error":
            guard let code = dict["code"] as? String else { return nil }
            return .error(code: code)
        default:
            return nil
        }
    }

    private static func parseTerms(_ value: Any?) -> [TranscriptTerm] {
        guard let array = value as? [Any],
              let data = try? JSONSerialization.data(withJSONObject: array)
        else { return [] }
        let decoder = JSONDecoder()
        guard let raw = try? decoder.decode([FailableTerm].self, from: data) else { return [] }
        return raw.compactMap(\.term)
    }
}

/// Decodes a term or swallows the element when its shape is wrong.
private struct FailableTerm: Decodable {
    let term: TranscriptTerm?
    init(from decoder: Decoder) throws {
        term = try? TranscriptTerm(from: decoder)
    }
}

enum WsConnectionStatus: String {
    case disconnected, connecting, connected, reconnecting, error

    var russianLabel: String {
        switch self {
        case .disconnected: "отключено"
        case .connecting: "подключение"
        case .connected: "в эфире"
        case .reconnecting: "переподключение"
        case .error: "ошибка"
        }
    }
}

// MARK: - Backend status

struct HealthDto: Codable {
    let status: String
    let version: String
}

struct BackendComponentDto: Codable {
    let ready: Bool
    let required: Bool
    let details: String
}

struct ReadyDto: Codable {
    let ready: Bool
    let components: [String: BackendComponentDto]
}

struct BackendComponent: Identifiable {
    let name: String
    let ready: Bool
    let required: Bool
    let details: String
    var id: String { name }
}

// MARK: - Meetings (JSON-compatible with the Electron app's meetings.json)

struct MeetingQA: Codable, Hashable {
    var question: String
    var answer: String
    var points: [String]
    var example: String
}

struct MeetingRecord: Codable, Identifiable, Hashable {
    var id: String
    var startedAt: Double
    var endedAt: Double
    var context: String
    var transcript: String
    var qa: [MeetingQA]
}

// MARK: - Errors

struct BackendError: LocalizedError {
    let message: String
    let status: Int
    var code: String?

    var errorDescription: String? { message }
}
