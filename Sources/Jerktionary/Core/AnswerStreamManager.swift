import Foundation

/// Streams and caches live answers per question+depth — port of useLiveAnswer's
/// module-wide inflight map: a stream keeps running even when no card shows it,
/// and the shallow answer pre-generates the deep variant in the background.
@MainActor
final class AnswerStreamManager: ObservableObject {
    struct Key: Hashable {
        let question: String
        let deep: Bool
    }

    struct StreamState {
        var latest: LiveAnswer?
        var done = false
        var error: String?
    }

    @Published private(set) var cache: [Key: LiveAnswer] = [:]
    @Published private(set) var inflight: [Key: StreamState] = [:]

    private var tasks: [Key: Task<Void, Never>] = [:]
    private unowned let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    func state(question: String, deep: Bool) -> (answer: LiveAnswer?, streaming: Bool, error: String?) {
        let key = Key(question: question, deep: deep)
        if let cached = cache[key] {
            return (cached, false, nil)
        }
        if let stream = inflight[key] {
            return (stream.latest, !stream.done, stream.error)
        }
        return (nil, false, nil)
    }

    func ensureStream(question: String, deep: Bool, context: String) {
        let key = Key(question: question, deep: deep)
        guard cache[key] == nil, tasks[key] == nil else { return }

        inflight[key] = StreamState()
        store.answerStreamingCount += 1
        let truncateContext = !store.popFullContext()
        let client = store.backendClient
        let profile = store.settings.aboutMe
        let meetingContext = store.meetingContext

        tasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = client.answerStream(
                    question: question,
                    context: context,
                    deep: deep,
                    profile: profile,
                    meetingContext: meetingContext,
                    truncateContext: truncateContext
                )
                var final: LiveAnswer?
                for try await (answer, _) in stream {
                    final = answer
                    self.inflight[key]?.latest = answer
                }
                if let final {
                    self.cache[key] = final
                    self.store.recordAnswer(question: question, answer: final)
                    // Pre-generate the detailed variant so "Подробнее" is instant.
                    if !deep, self.cache[Key(question: question, deep: true)] == nil {
                        self.ensureStream(question: question, deep: true, context: context)
                    }
                }
            } catch {
                self.inflight[key]?.error = error.localizedDescription
            }
            self.inflight[key]?.done = true
            self.tasks[key] = nil
            self.store.answerStreamingCount = max(0, self.store.answerStreamingCount - 1)
            // Keep errored streams visible until regenerate; successful ones move to cache.
            if self.inflight[key]?.error == nil {
                self.inflight[key] = nil
            }
        }
    }

    func regenerate(question: String, deep: Bool, context: String) {
        let key = Key(question: question, deep: deep)
        guard tasks[key] == nil else { return }
        cache[key] = nil
        inflight[key] = nil
        ensureStream(question: question, deep: deep, context: context)
    }

    func resetSession() {
        for task in tasks.values {
            task.cancel()
        }
        tasks = [:]
        inflight = [:]
        cache = [:]
    }
}
