import Foundation

/// Term-explanation cache with background prefetch — port of useTermExplanation
/// + useExplanationPrefetch: one request at a time with a small gap, paused
/// while an answer is streaming to avoid competing for the LLM/GPU.
@MainActor
final class ExplanationManager: ObservableObject {
    @Published private(set) var cache: [String: TermExplanation] = [:]
    @Published private(set) var streaming: [String: TermExplanation] = [:]
    @Published private(set) var errors: [String: String] = [:]

    private static let maxPrefetchTerms = 12
    private static let prefetchGapMs: UInt64 = 300
    private static let answerBusyWaitMs: UInt64 = 400

    private var queue: [String] = []
    private var enqueued: Set<String> = []
    private var draining = false
    private var activeStreams: Set<String> = []
    private unowned let store: AppStore

    init(store: AppStore) {
        self.store = store
    }

    // MARK: Interactive fetch (term popover) — streaming for fast first paint.

    func fetchStreaming(term: String, context: String) {
        let normalized = term.lowercased()
        guard cache[normalized] == nil, !activeStreams.contains(normalized) else { return }
        activeStreams.insert(normalized)
        errors[normalized] = nil
        let client = store.backendClient

        Task { [weak self] in
            guard let self else { return }
            do {
                for try await (explanation, _) in client.explainTermStream(term, context: context) {
                    self.streaming[normalized] = explanation
                }
                if let final = self.streaming[normalized] {
                    self.cache[normalized] = final
                    self.store.addLastExplanation(term: term, explanation: final)
                }
            } catch {
                self.errors[normalized] = error.localizedDescription
            }
            self.streaming[normalized] = nil
            self.activeStreams.remove(normalized)
        }
    }

    func state(term: String) -> (explanation: TermExplanation?, loading: Bool, error: String?) {
        let normalized = term.lowercased()
        if let cached = cache[normalized] {
            return (cached, false, nil)
        }
        if let partial = streaming[normalized] {
            return (partial, true, nil)
        }
        if activeStreams.contains(normalized) {
            return (nil, true, nil)
        }
        return (nil, false, errors[normalized])
    }

    // MARK: Background prefetch

    func prefetch(terms: [TranscriptTerm], context: String) {
        for term in terms.suffix(Self.maxPrefetchTerms) {
            let normalized = term.normalized.lowercased()
            guard cache[normalized] == nil, !enqueued.contains(normalized) else { continue }
            enqueued.insert(normalized)
            queue.append(term.normalized)
        }
        drainQueue(context: context)
    }

    private func drainQueue(context: String) {
        guard !draining else { return }
        draining = true
        let client = store.backendClient

        Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let term = self.queue.removeFirst()
                // Don't compete with live answer generation.
                while self.store.answerStreamingCount > 0 {
                    try? await Task.sleep(nanoseconds: Self.answerBusyWaitMs * 1_000_000)
                }
                if self.cache[term.lowercased()] == nil,
                   let explanation = try? await client.explainTerm(term, context: context) {
                    self.cache[term.lowercased()] = explanation
                }
                try? await Task.sleep(nanoseconds: Self.prefetchGapMs * 1_000_000)
            }
            self?.draining = false
        }
    }
}
