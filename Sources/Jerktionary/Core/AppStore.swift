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
    @Published var microphoneLevel: Double = 0
    @Published private(set) var answeredQuestions: [String] = []
    @Published private(set) var sessionAnswers: [SessionAnswer] = []
    @Published private(set) var lastExplanations: [LastExplanation] = []
    @Published var meetingContext = ""
    @Published var microphoneError: String?
    @Published var websocketError: String?

    // MARK: Backend status
    @Published private(set) var backendReady = false
    @Published private(set) var backendComponents: [BackendComponent] = []
    @Published private(set) var backendUnavailable = false
    @Published private(set) var backendStatusLoaded = false
    @Published private(set) var backendVersion: String?

    // MARK: UI state
    @Published var overlayMode = false
    @Published var contentProtectionEnabled = true
    @Published var sidebarVisible = true
    /// Which main working area is shown. Purely a view switch: the listening
    /// pipeline (audio + WebSocket + answer streams) runs in this store and is
    /// unaffected, so transcription and answers keep going in the Notes tab.
    @Published var mainTab: MainTab = .session
    /// Meeting opened from the sidebar history (shown as an in-window modal).
    @Published var selectedMeeting: MeetingRecord?

    private(set) var meetingStartedAt: Date?
    private var fullContextRequested = false
    var answerStreamingCount = 0

    let settings: AppSettings
    let meetings: MeetingsStore
    let notes: NotesStore
    lazy var answers = AnswerStreamManager(store: self)
    lazy var explanations = ExplanationManager(store: self)

    private var wsClient: TranscriptWSClient?
    private var micCapture: MicrophoneCapture?
    private var systemCapture: SystemAudioCapture?
    private var statusPollTask: Task<Void, Never>?
    private var questionSettleTask: Task<Void, Never>?

    var backendClient: BackendClient {
        BackendClient(baseUrl: settings.normalizedHttpUrl)
    }

    init(settings: AppSettings) {
        self.settings = settings
        self.meetings = MeetingsStore()
        self.notes = NotesStore()
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
        microphoneLevel = 0

        // Archive the finished meeting; failures must not break stopping.
        if let record = buildMeetingRecord() {
            meetings.save(record)
        }
    }

    private func connectWebSocket() {
        guard let url = settings.websocketUrl else {
            websocketError = "Некорректный адрес backend"
            return
        }
        wsClient?.disconnect()
        let client = TranscriptWSClient(url: url)
        client.onEvent = { [weak self] event in
            Task { @MainActor in self?.handleWsEvent(event) }
        }
        client.onStatus = { [weak self] status in
            Task { @MainActor in self?.connectionStatus = status }
        }
        client.onError = { [weak self] message in
            Task { @MainActor in self?.websocketError = message }
        }
        wsClient = client
        client.connect()
    }

    private func startMicrophone() async throws {
        let capture = MicrophoneCapture()
        micCapture = capture
        try await capture.start(
            deviceUID: settings.audioInputDeviceUID,
            onChunk: { [weak self] data in
                Task { @MainActor in self?.wsClient?.sendAudioChunk(data) }
            },
            onLevel: { [weak self] level in
                Task { @MainActor in self?.microphoneLevel = level }
            }
        )
    }

    private func startSystemAudio() async throws {
        let capture = SystemAudioCapture()
        systemCapture = capture
        try await capture.start(
            onChunk: { [weak self] data in
                Task { @MainActor in self?.wsClient?.sendAudioChunk(data) }
            },
            onLevel: { [weak self] level in
                Task { @MainActor in self?.microphoneLevel = level }
            },
            onStopError: { [weak self] message in
                Task { @MainActor in self?.microphoneError = message }
            }
        )
    }

    // MARK: - WebSocket events

    private func handleWsEvent(_ event: BackendWsEvent) {
        switch event {
        case .transcriptUpdate(let text, _, let eventTerms):
            currentText = text
            terms = eventTerms
            scheduleQuestionDetection()
            explanations.prefetch(terms: terms, context: currentText)
        case .termsUpdate(let items):
            terms = TermMerger.merge(terms, items)
            explanations.prefetch(terms: terms, context: currentText)
        case .error(let code):
            let messages: [String: String] = [
                "INVALID_AUDIO_CHUNK": "Backend отклонил audio chunk: ожидается binary PCM 16 kHz mono int16",
                "ASR_UNAVAILABLE": "Локальный Whisper выключен на backend. Выберите API-провайдера распознавания в настройках.",
                "ASR_API_ERROR": "API-провайдер распознавания отклонил запрос: проверьте ключ и модель в настройках.",
                "INVALID_CONFIG": "Backend не принял конфигурацию распознавания."
            ]
            websocketError = messages[code] ?? "Backend WebSocket error: \(code)"
        }
    }

    // MARK: - Question detection (settle-window port of useLiveQuestion)

    private func scheduleQuestionDetection() {
        questionSettleTask?.cancel()
        let text = currentText
        let detected = QuestionDetector.latestQuestion(in: text)
        let delayMs: UInt64 = detected?.hasSuffix("?") == true ? 350 : 1200
        questionSettleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            if let question = QuestionDetector.latestQuestion(in: self.currentText) {
                self.pushQuestion(question)
            }
        }
    }

    func pushQuestion(_ question: String) {
        let key = QuestionDetector.questionKey(question)
        guard !key.isEmpty else { return }
        // Whisper re-decodes paraphrase the same question; the canonical key keeps
        // one card per question instead of spawning duplicates.
        if answeredQuestions.contains(where: { QuestionDetector.questionKey($0) == key }) {
            return
        }
        answeredQuestions = Array(([question] + answeredQuestions).prefix(8))
        answers.ensureStream(question: question, deep: false, context: currentText)
    }

    /// Ctrl+Shift+Space: force-answer the last spoken sentence(s).
    func answerNow() {
        if let forced = QuestionDetector.forcedQuestion(in: currentText) {
            pushQuestion(forced)
        }
    }

    /// Ctrl+Shift+Enter: answer the last sentence with the full transcript as context.
    func fullContextAnswer() {
        guard !currentText.isEmpty,
              let question = QuestionDetector.lastSentence(in: currentText)
        else { return }
        fullContextRequested = true
        pushQuestion(question)
    }

    func popFullContext() -> Bool {
        defer { fullContextRequested = false }
        return fullContextRequested
    }

    func recordAnswer(question: String, answer: LiveAnswer) {
        if let index = sessionAnswers.firstIndex(where: { $0.question == question }) {
            sessionAnswers[index].answer = answer
        } else {
            sessionAnswers.append(SessionAnswer(question: question, answer: answer))
        }
    }

    func addLastExplanation(term: String, explanation: TermExplanation) {
        lastExplanations = Array(
            ([LastExplanation(term: term, explanation: explanation, loadedAt: .now)]
                + lastExplanations.filter { $0.term != term }).prefix(6)
        )
    }

    // MARK: - Session / meetings

    private func resetSession() {
        // meetingContext survives on purpose: it's filled before pressing "Слушать".
        currentText = ""
        terms = []
        answeredQuestions = []
        sessionAnswers = []
        meetingStartedAt = .now
        microphoneLevel = 0
        websocketError = nil
        microphoneError = nil
        answers.resetSession()
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
