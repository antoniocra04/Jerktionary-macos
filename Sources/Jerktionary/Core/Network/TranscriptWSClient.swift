import Foundation

/// WebSocket audio-transport client: sends binary PCM chunks, receives JSON
/// transcript events. Reconnects with exponential backoff (500ms → 5s) unless
/// closed manually — a port of the web TranscriptWsClient.
final class TranscriptWSClient: NSObject, @unchecked Sendable {
    var onEvent: (@Sendable (BackendWsEvent) -> Void)?
    var onStatus: (@Sendable (WsConnectionStatus) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    private let url: URL
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reconnectAttempt = 0
    private var reconnectTimer: Timer?
    private var manuallyClosed = false

    init(url: URL) {
        self.url = url
        super.init()
    }

    func connect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        manuallyClosed = false
        onStatus?(reconnectAttempt > 0 ? .reconnecting : .connecting)

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop(task)
    }

    func disconnect() {
        manuallyClosed = true
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        task?.cancel(with: .normalClosure, reason: "listening stopped".data(using: .utf8))
        task = nil
        session?.invalidateAndCancel()
        session = nil
        onStatus?(.disconnected)
    }

    @discardableResult
    func sendAudioChunk(_ chunk: Data) -> Bool {
        guard let task, task.state == .running else { return false }
        task.send(.data(chunk)) { _ in }
        return true
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let event = BackendWsEvent.parse(Data(text.utf8)) {
                        self.onEvent?(event)
                    } else {
                        self.onError?("Backend прислал неизвестное WebSocket событие")
                    }
                case .data:
                    self.onError?("Backend прислал не-JSON WebSocket сообщение")
                @unknown default:
                    break
                }
                self.receiveLoop(task)
            case .failure:
                self.handleClose()
            }
        }
    }

    private func handleClose() {
        task = nil
        if manuallyClosed {
            onStatus?(.disconnected)
            return
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectAttempt += 1
        onStatus?(.reconnecting)
        let delay = min(0.5 * pow(2, Double(reconnectAttempt - 1)), 5.0)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.connect()
            }
        }
    }
}

extension TranscriptWSClient: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        reconnectAttempt = 0
        onStatus?(.connected)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        handleClose()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            onStatus?(.error)
            onError?("Ошибка WebSocket соединения")
            handleClose()
        }
    }
}
