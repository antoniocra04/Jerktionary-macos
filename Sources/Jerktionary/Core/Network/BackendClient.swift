import Foundation

/// REST + SSE client for the transcription backend.
struct BackendClient {
    var baseUrl: String

    // MARK: REST

    func health() async throws -> HealthDto {
        try await getJSON("/health")
    }

    func ready() async throws -> (ready: Bool, components: [BackendComponent]) {
        let dto: ReadyDto = try await getJSON("/ready")
        let components = dto.components
            .map { BackendComponent(name: $0.key, ready: $0.value.ready, required: $0.value.required, details: $0.value.details) }
            .sorted { $0.name < $1.name }
        return (dto.ready, components)
    }

    func explainTerm(_ term: String, context: String) async throws -> TermExplanation {
        struct RequestDto: Encodable {
            let term: String
            let context: String
        }
        struct ResponseDto: Decodable {
            let title: String
            let short: String
            let example: String
            let why_important: String
            let source: String
        }
        let dto: ResponseDto = try await postJSON(
            "/api/terms/explain",
            body: RequestDto(term: term, context: Self.termContext(context, term: term, size: 2000))
        )
        return TermExplanation(
            title: dto.title,
            short: dto.short,
            example: dto.example,
            whyImportant: dto.why_important,
            source: ExplanationSource(rawValue: dto.source) ?? .localLLM
        )
    }

    // MARK: SSE streams

    struct AnswerSnapshot: Decodable {
        var answer: String?
        var points: String?
        var example: String?
        var done: Bool?
        var error: String?
    }

    /// Streams `/api/answer/stream`, yielding progressively complete answers.
    func answerStream(
        question: String,
        context: String,
        deep: Bool,
        profile: String,
        meetingContext: String,
        truncateContext: Bool
    ) -> AsyncThrowingStream<(LiveAnswer, Bool), Error> {
        struct RequestDto: Encodable {
            let question: String
            let context: String
            let deep: Bool
            let profile: String
            let meeting_context: String
        }
        // The transcript grows from the start: the relevant conversation is the tail.
        let slicedContext = truncateContext ? String(context.suffix(2000)) : context
        let body = RequestDto(
            question: question,
            context: slicedContext,
            deep: deep,
            profile: String(profile.prefix(1000)),
            meeting_context: String(meetingContext.prefix(2000))
        )
        return sseStream(path: "/api/answer/stream", body: body) { (snapshot: AnswerSnapshot) in
            if let error = snapshot.error {
                throw BackendError(message: "Модель вернула ошибку", status: 502, code: error)
            }
            let answer = LiveAnswer(
                answer: snapshot.answer ?? "",
                points: Self.parsePoints(snapshot.points ?? ""),
                example: snapshot.example ?? ""
            )
            return (answer, snapshot.done ?? false)
        }
    }

    struct ExplanationSnapshot: Decodable {
        var title: String?
        var short: String?
        var example: String?
        var why_important: String?
        var source: String?
        var done: Bool?
        var error: String?
    }

    /// Streams `/api/terms/explain/stream` for a term.
    func explainTermStream(
        _ term: String,
        context: String
    ) -> AsyncThrowingStream<(TermExplanation, Bool), Error> {
        struct RequestDto: Encodable {
            let term: String
            let context: String
        }
        let body = RequestDto(term: term, context: Self.termContext(context, term: term, size: 2000))
        return sseStream(path: "/api/terms/explain/stream", body: body) { (snapshot: ExplanationSnapshot) in
            if let error = snapshot.error {
                throw BackendError(message: "Модель вернула ошибку", status: 502, code: error)
            }
            let explanation = TermExplanation(
                title: snapshot.title ?? "",
                short: snapshot.short ?? "",
                example: snapshot.example ?? "",
                whyImportant: snapshot.why_important ?? "",
                source: ExplanationSource(rawValue: snapshot.source ?? "") ?? .localLLM
            )
            return (explanation, snapshot.done ?? false)
        }
    }

    // MARK: - Helpers

    /// Window of `size` chars centered on the last mention of `term`; falls back
    /// to the transcript tail when the term isn't found verbatim.
    static func termContext(_ text: String, term: String, size: Int) -> String {
        let lowerText = text.lowercased()
        guard let range = lowerText.range(of: term.lowercased(), options: .backwards) else {
            return String(text.suffix(size))
        }
        let index = lowerText.distance(from: lowerText.startIndex, to: range.lowerBound)
        let start = max(0, index - size / 2)
        let startIndex = text.index(text.startIndex, offsetBy: min(start, text.count))
        let endIndex = text.index(startIndex, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[startIndex..<endIndex])
    }

    static func parsePoints(_ raw: String) -> [String] {
        raw.split(separator: "\n")
            .map { line in
                line.replacingOccurrences(of: "^\\s*[-•*]\\s*", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
    }

    private func getJSON<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: baseUrl + path) else {
            throw BackendError(message: "Некорректный адрес backend", status: 0)
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await perform(request)
    }

    private func postJSON<T: Decodable>(_ path: String, body: some Encodable) async throws -> T {
        guard let url = URL(string: baseUrl + path) else {
            throw BackendError(message: "Некорректный адрес backend", status: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw BackendError(message: "Backend недоступен. Проверьте адрес и что backend запущен.", status: 0)
        }
        guard let http = response as? HTTPURLResponse else {
            throw BackendError(message: "Некорректный ответ backend", status: 0)
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(ApiErrorPayload.self, from: data)
            throw BackendError(
                message: payload?.message ?? "HTTP \(http.statusCode)",
                status: http.statusCode,
                code: payload?.code
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct ApiErrorPayload: Decodable {
        let code: String
        let message: String
    }

    /// POSTs and parses `data:` lines of an SSE body, transforming each JSON
    /// snapshot with `transform`. Events are separated by blank lines.
    private func sseStream<Snapshot: Decodable, Output>(
        path: String,
        body: some Encodable,
        transform: @escaping @Sendable (Snapshot) throws -> Output
    ) -> AsyncThrowingStream<Output, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let url = URL(string: baseUrl + path) else {
                    continuation.finish(throwing: BackendError(message: "Некорректный адрес backend", status: 0))
                    return
                }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                do {
                    request.httpBody = try JSONEncoder().encode(body)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        throw BackendError(message: "HTTP \(status)", status: status)
                    }

                    var sawSnapshot = false
                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8) else { continue }
                        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                        continuation.yield(try transform(snapshot))
                        sawSnapshot = true
                    }
                    if !sawSnapshot {
                        throw BackendError(message: "Пустой поток ответа", status: 502)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
