import Foundation

/// Streams and caches answers requested explicitly by the user. Only one answer
/// request may run at a time; transcript updates never enter this type.
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
    @Published private(set) var activeKey: Key?

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

    var isGenerating: Bool { activeKey != nil }

    @discardableResult
    func ensureStream(
        question: String,
        deep: Bool,
        context: String,
        fullContext: Bool = false
    ) -> Bool {
        let key = Key(question: question, deep: deep)
        guard cache[key] == nil, tasks[key] == nil, activeKey == nil else { return false }

        inflight[key] = StreamState()
        activeKey = key
        store.answerStreamingCount += 1
        let truncateContext = !fullContext
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
                    self.store.showNotice(deep ? "Подробный ответ готов" : "Ответ готов")
                }
            } catch {
                if !Task.isCancelled {
                    self.inflight[key]?.error = error.localizedDescription
                    AccessibilityAnnouncer.announce(error.localizedDescription)
                }
            }
            self.inflight[key]?.done = true
            self.tasks[key] = nil
            if self.activeKey == key { self.activeKey = nil }
            self.store.answerStreamingCount = max(0, self.store.answerStreamingCount - 1)
            // Keep errored streams visible until regenerate; successful ones move to cache.
            if self.inflight[key]?.error == nil {
                self.inflight[key] = nil
            }
        }
        return true
    }

    func regenerate(question: String, deep: Bool, context: String) {
        let key = Key(question: question, deep: deep)
        guard tasks[key] == nil, activeKey == nil else {
            store.showNotice("Ответ уже готовится")
            return
        }
        cache[key] = nil
        inflight[key] = nil
        ensureStream(question: question, deep: deep, context: context)
    }

    @discardableResult
    func cancelCurrent() -> Bool {
        guard let activeKey, let task = tasks[activeKey] else { return false }
        task.cancel()
        tasks[activeKey] = nil
        inflight[activeKey] = StreamState(done: true, error: "Генерация остановлена")
        self.activeKey = nil
        store.answerStreamingCount = max(0, store.answerStreamingCount - 1)
        return true
    }

    #if DEBUG
    func seedForPreview(question: String, answer: LiveAnswer) {
        cache[Key(question: question, deep: false)] = answer
    }
    #endif

    func resetSession() {
        for task in tasks.values {
            task.cancel()
        }
        tasks = [:]
        inflight = [:]
        cache = [:]
        activeKey = nil
    }
}
