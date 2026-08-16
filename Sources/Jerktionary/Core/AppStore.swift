import Foundation
import SwiftUI

struct SessionAnswer: Identifiable {
    let question: String
    var answer: LiveAnswer
    var id: String { question }
}

struct LastExplanation: Identifiable {
    let term: String
    let explanation: TermExplanation
    let loadedAt: Date
    var id: String { term }
}

/// Central observable state — the SwiftUI counterpart of the zustand transcript
/// store plus the listening pipeline (audio capture + WebSocket).
@MainActor
final class AppStore: ObservableObject {
    // MARK: Transcript state
    @Published private(set) var currentText = ""
    @Published private(set) var terms: [TranscriptTerm] = []
    @Published private(set) var connectionStatus: WsConnectionStatus = .disconnected
    @Published private(set) var isListening = false
    @Published private(set) var answerRequests: [String] = []
    @Published private(set) var sessionAnswers: [SessionAnswer] = []
    @Published private(set) var lastExplanations: [LastExplanation] = []
    @Published var meetingContext = ""
    @Published var microphoneError: String?
    @Published var websocketError: String?
    @Published var transientNotice: String?

    // MARK: Backend status
    @Published private(set) var backendReady = false
    @Published private(set) var backendComponents: [BackendComponent] = []
    @Published private(set) var backendUnavailable = false
    @Published private(set) var backendStatusLoaded = false
    @Published private(set) var backendVersion: String?

    // MARK: UI state
    @Published var overlayMode = false
    @Published var contentProtectionEnabled = true
    // The live assistant is the primary surface. History remains one toolbar
    // click away instead of consuming a quarter of every fresh session.
    @Published var sidebarVisible = false
    @Published private(set) var sessionHasUnreadAnswer = false
    /// Which main working area is shown. Purely a view switch: the listening
    /// pipeline (audio + WebSocket + answer streams) runs in this store and is
    /// unaffected, so transcription and answers keep going in the Notes tab.
    @Published var mainTab: MainTab = .session {
        didSet {
            if mainTab == .session { sessionHasUnreadAnswer = false }
        }
    }
    /// Meeting opened from the sidebar history (shown as an in-window modal).
    @Published var selectedMeeting: MeetingRecord?

    private(set) var meetingStartedAt: Date?
    @Published var answerStreamingCount = 0

    let settings: AppSettings
    let meetings: MeetingsStore
    let notes: NotesStore
    let chats: ChatStore
    /// Not `@Published`: see AudioLevelModel — the meter observes it directly so
    /// the ~12 Hz level updates don't invalidate the rest of the UI.
    let audioLevel = AudioLevelModel()
    lazy var answers = AnswerStreamManager(store: self)
    lazy var explanations = ExplanationManager(store: self)

    private var wsClient: TranscriptWSClient?
    private var micCapture: MicrophoneCapture?
    private var systemCapture: SystemAudioCapture?
    private var statusPollTask: Task<Void, Never>?
    var backendClient: BackendClient {
        BackendClient(baseUrl: settings.normalizedHttpUrl)
    }

    init(settings: AppSettings) {
        self.settings = settings
        self.meetings = MeetingsStore()
        self.notes = NotesStore()
        self.chats = ChatStore()
        startBackendStatusPolling()
    }

    // MARK: - Listening pipeline

    func toggleListening() async {
        if isListening {
            await stopListening()
        } else {
            await startListening()
        }
    }

    func startListening() async {
        resetSession()
        isListening = true
        microphoneError = nil
        connectWebSocket()

        do {
            switch settings.audioSource {
            case .microphone:
                try await startMicrophone()
            case .system:
                try await startSystemAudio()
            }
            showNotice("Listening started")
        } catch {
            wsClient?.disconnect()
            wsClient = nil
            isListening = false
            microphoneError = error.localizedDescription
        }
    }

    func stopListening() async {
        isListening = false
        micCapture?.stop()
        micCapture = nil
        if let systemCapture {
            await systemCapture.stop()
        }
        systemCapture = nil
        wsClient?.disconnect()
        wsClient = nil
        audioLevel.level = 0

        // Archive the finished meeting; failures must not break stopping.
        if let record = buildMeetingRecord() {
            meetings.save(record)
            showNotice("Meeting saved")
        } else {
            showNotice("Listening stopped")
        }
    }

    private func connectWebSocket() {
        guard let url = settings.websocketUrl else {
            websocketError = "Invalid answer service address"
            return
        }
        wsClient?.disconnect()
        let client = TranscriptWSClient(url: url)
        client.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.handleWsEvent(event) }
        }
        client.onStatus = { [weak self] status in
            Task { @MainActor [weak self] in self?.updateConnectionStatus(status) }
        }
        client.onError = { [weak self] message in
            Task { @MainActor [weak self] in self?.websocketError = message }
        }
        wsClient = client
        client.connect()
    }

    private func updateConnectionStatus(_ status: WsConnectionStatus) {
        let wasInterrupted = connectionStatus == .reconnecting || connectionStatus == .error
        connectionStatus = status
        if wasInterrupted, status == .connected {
            showNotice("Connection restored")
        }
    }

    private func startMicrophone() async throws {
        let capture = MicrophoneCapture()
        micCapture = capture
        try await capture.start(
            deviceUID: settings.audioInputDeviceUID,
            onChunk: { [weak self] data in
                Task { @MainActor [weak self] in self?.wsClient?.sendAudioChunk(data) }
            },
            onLevel: { [weak self] level in
                Task { @MainActor [weak self] in self?.audioLevel.level = level }
            }
        )
    }

    private func startSystemAudio() async throws {
        let capture = SystemAudioCapture()
        systemCapture = capture
        try await capture.start(
            onChunk: { [weak self] data in
                Task { @MainActor [weak self] in self?.wsClient?.sendAudioChunk(data) }
            },
            onLevel: { [weak self] level in
                Task { @MainActor [weak self] in self?.audioLevel.level = level }
            },
            onStopError: { [weak self] message in
                Task { @MainActor [weak self] in self?.microphoneError = message }
            }
        )
    }

    // MARK: - WebSocket events

    private func handleWsEvent(_ event: BackendWsEvent) {
        switch event {
        case .transcriptUpdate(let text, _, let eventTerms):
            currentText = text
            terms = eventTerms
            explanations.prefetch(terms: terms, context: currentText)
        case .termsUpdate(let items):
            terms = TermMerger.merge(terms, items)
            explanations.prefetch(terms: terms, context: currentText)
        case .error(let code):
            let messages: [String: String] = [
                "INVALID_AUDIO_CHUNK": "The service rejected the audio. Check the audio source in Settings.",
                "ASR_UNAVAILABLE": "Speech recognition is unavailable. Open diagnostics in Settings.",
                "ASR_API_ERROR": "The recognition service rejected the request. Check the connection and settings.",
                "INVALID_CONFIG": "The service rejected the recognition settings."
            ]
            websocketError = messages[code] ?? "Recognition service error: \(code)"
        }
    }

    // MARK: - Explicit answer requests

    /// Ctrl+Shift+Space: freeze the latest utterance and answer only because the
    /// user explicitly asked. Transcript updates never call this path.
    func answerNow() {
        guard let excerpt = TranscriptExcerpt.latest(in: currentText) else {
            showNotice("Not enough speech yet to answer")
            return
        }
        requestAnswer(question: excerpt, fullContext: false)
    }

    /// Ctrl+Shift+Enter: the same explicit action, with the full transcript.
    func fullContextAnswer() {
        guard let excerpt = TranscriptExcerpt.latest(in: currentText) else {
            showNotice("Not enough speech yet to answer")
            return
        }
        requestAnswer(question: excerpt, fullContext: true)
    }

    @discardableResult
    func requestAnswer(question: String, fullContext: Bool = false) -> Bool {
        let frozen = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !frozen.isEmpty else {
            showNotice("Type your request")
            return false
        }
        guard backendReady, !backendUnavailable else {
            showNotice("The answer service is unavailable right now")
            return false
        }
        guard !answers.isGenerating else {
            showNotice("An answer is already being prepared")
            return false
        }

        answerRequests = Array(([frozen] + answerRequests.filter { $0 != frozen }).prefix(8))
        let started = answers.ensureStream(
            question: frozen,
            deep: false,
            context: currentText,
            fullContext: fullContext
        )
        if !started, answers.state(question: frozen, deep: false).answer == nil {
            answerRequests.removeAll { $0 == frozen }
            return false
        }
        return true
    }

    func cancelAnswer() {
        guard answers.cancelCurrent() else { return }
        showNotice("Generation stopped")
    }

    func showNotice(_ message: String) {
        transientNotice = message
        AccessibilityAnnouncer.announce(message)
    }

    func recordAnswer(question: String, answer: LiveAnswer) {
        if let index = sessionAnswers.firstIndex(where: { $0.question == question }) {
            sessionAnswers[index].answer = answer
        } else {
            sessionAnswers.append(SessionAnswer(question: question, answer: answer))
        }
        if mainTab != .session { sessionHasUnreadAnswer = true }
    }

    func addLastExplanation(term: String, explanation: TermExplanation) {
        lastExplanations = Array(
            ([LastExplanation(term: term, explanation: explanation, loadedAt: .now)]
                + lastExplanations.filter { $0.term != term }).prefix(6)
        )
    }

    // MARK: - Session / meetings

    private func resetSession() {
        // meetingContext survives on purpose: it's filled before pressing "Listen".
        currentText = ""
        terms = []
        answerRequests = []
        sessionAnswers = []
        meetingStartedAt = .now
        audioLevel.level = 0
        websocketError = nil
        microphoneError = nil
        transientNotice = nil
        sessionHasUnreadAnswer = false
        answers.resetSession()
        // Reset synchronously: cancelled answer tasks finish on a later turn of
        // the main actor and must not keep explanation prefetch paused in the
        // freshly started session.
        answerStreamingCount = 0
    }

    private func buildMeetingRecord() -> MeetingRecord? {
        let transcript = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let qa = sessionAnswers.map {
            MeetingQA(
                question: $0.question,
                answer: $0.answer.answer,
                points: $0.answer.points,
                example: $0.answer.example
            )
        }
        guard !transcript.isEmpty || !qa.isEmpty else { return nil }
        let startedAt = meetingStartedAt ?? .now
        return MeetingRecord(
            id: "\(Int(startedAt.timeIntervalSince1970 * 1000))-\(String(UUID().uuidString.prefix(6)).lowercased())",
            startedAt: startedAt.timeIntervalSince1970 * 1000,
            endedAt: Date.now.timeIntervalSince1970 * 1000,
            context: meetingContext.trimmingCharacters(in: .whitespacesAndNewlines),
            transcript: transcript,
            qa: qa
        )
    }

    #if DEBUG
    /// Fills a session so the UI can be inspected with real content. Compiled
    /// out of release builds; the app never calls it.
    func seedForPreview(questions: [String], answer: LiveAnswer) {
        answerRequests = questions
        for question in questions {
            answers.seedForPreview(question: question, answer: answer)
        }
    }

    #endif

    // MARK: - Backend status polling (30s, like useBackendStatus)

    func refreshBackendStatus() async {
        let client = backendClient
        do {
            let health = try await client.health()
            let ready = try await client.ready()
            backendVersion = health.version
            backendReady = ready.ready
            backendComponents = ready.components
            backendUnavailable = false
        } catch {
            backendUnavailable = true
            backendReady = false
        }
        backendStatusLoaded = true
    }

    private func startBackendStatusPolling() {
        statusPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshBackendStatus()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }
}
