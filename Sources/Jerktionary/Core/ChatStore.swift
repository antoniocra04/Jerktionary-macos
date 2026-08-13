import AppKit
import Foundation

/// An image attached to a chat message, kept as a base64 data: URI — the shape
/// the backend takes and the shape that survives JSON persistence unchanged.
struct ChatAttachment: Codable, Identifiable, Hashable {
    var id: String
    var dataURL: String
    /// Original file name when the image came from disk, for the UI only.
    var name: String

    var image: NSImage? {
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        else { return nil }
        return NSImage(data: data)
    }
}

struct ChatMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    var id: String
    var role: Role
    var text: String
    var attachments: [ChatAttachment]
    var createdAt: Double
    /// Set when the backend reported a failure instead of an answer.
    var error: String?

    static func new(role: Role, text: String, attachments: [ChatAttachment] = []) -> ChatMessage {
        ChatMessage(
            id: Self.freshID(),
            role: role,
            text: text,
            attachments: attachments,
            createdAt: Date.now.timeIntervalSince1970 * 1000,
            error: nil
        )
    }

    static func freshID() -> String {
        "\(Int(Date.now.timeIntervalSince1970 * 1000))-\(String(UUID().uuidString.prefix(6)).lowercased())"
    }
}

struct Conversation: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var messages: [ChatMessage]
    var createdAt: Double
    var updatedAt: Double
    /// Remembered per conversation so switching back restores how it was asked.
    var model: String
    var reasoningEffort: String

    static func new() -> Conversation {
        let now = Date.now.timeIntervalSince1970 * 1000
        return Conversation(
            id: ChatMessage.freshID(),
            title: "",
            messages: [],
            createdAt: now,
            updatedAt: now,
            model: "",
            reasoningEffort: ""
        )
    }

    /// The first user line, bounded the same way notes are — a pasted wall of
    /// text must not become a giant single-line label in the list.
    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(title.prefix(Note.titleLengthLimit))
        }
        guard let first = messages.first(where: { $0.role == .user }) else { return "Новый чат" }
        let head = first.text
            .prefix(Note.titleScanLimit)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if head.isEmpty {
            return first.attachments.isEmpty ? "Новый чат" : "Изображение"
        }
        return String(head.prefix(Note.titleLengthLimit))
    }
}

/// What the active backend provider can do. Fetched once per app launch; the
/// reasoning picker only exists when the provider advertises levels.
struct ChatCapabilities: Equatable {
    var provider: String = ""
    var label: String = ""
    var defaultModel: String = ""
    /// The model these capabilities describe.
    var model: String = ""
    /// Ids the provider is known to serve, offered in the picker.
    var models: [String] = []
    var reasoningLevels: [String] = []
    /// nil when the provider publishes no modality metadata — not a "no".
    var acceptsImages: Bool?
    var ready: Bool = false

    /// Only a definite no blocks attachments; silence leaves it to the provider.
    var refusesImages: Bool { acceptsImages == false }
}

/// Conversations archive plus the live streaming state, stored next to
/// notes.json in Application Support.
///
/// Streaming text deliberately does not go through `@Published` on every token:
/// as with the notes editor and the transcript, pushing a growing string through
/// SwiftUI's state graph costs time proportional to its length. Tokens land in
/// `streamingText`, a plain property, and a timer publishes at a fixed rate.
@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published private(set) var capabilities = ChatCapabilities()
    @Published private(set) var isStreaming = false
    /// Bumped at a fixed rate while streaming so the view redraws without every
    /// token invalidating the whole tree.
    @Published private(set) var streamTick = 0
    /// The open conversation. Lives here rather than in the view because the
    /// screenshot hotkey has to drop its image into the one being looked at.
    @Published var selectedID: String?
    /// Attachments handed in from outside the composer — currently the
    /// screenshot hotkey. The open composer drains this into its own draft.
    @Published var pendingAttachments: [ChatAttachment] = []
    /// Shown by the chat tab when a capture failed; cleared once displayed.
    @Published var transientError: String?

    /// The answer as it arrives. Read during a redraw; never published directly.
    private(set) var streamingText = ""
    private(set) var streamingConversationID: String?

    private static let persistDebounceNanos: UInt64 = 400_000_000
    /// ~20 fps: fast enough to read as live typing, slow enough that a long
    /// answer doesn't re-render the transcript hundreds of times.
    private static let streamPublishInterval: UInt64 = 50_000_000

    private let ioQueue = DispatchQueue(label: "com.jerktionary.chat.io", qos: .utility)
    private var persistTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?

    private var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jerktionary", isDirectory: true)
            .appendingPathComponent("chats.json")
    }

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let parsed = try? JSONDecoder().decode([Conversation].self, from: data)
        else {
            conversations = []
            return
        }
        conversations = parsed.sorted { $0.updatedAt > $1.updatedAt }
        selectedID = conversations.first?.id
    }

    func conversation(id: String) -> Conversation? {
        conversations.first { $0.id == id }
    }

    @discardableResult
    func create() -> Conversation {
        let conversation = Conversation.new()
        conversations.insert(conversation, at: 0)
        selectedID = conversation.id
        persistNow()
        return conversation
    }

    /// The conversation a screenshot or a new message should land in: whatever is
    /// open, else the most recent, else a fresh one.
    func currentOrNewConversation() -> Conversation {
        if let selectedID, let existing = conversation(id: selectedID) {
            return existing
        }
        if let first = conversations.first {
            selectedID = first.id
            return first
        }
        return create()
    }

    func delete(_ id: String) {
        if streamingConversationID == id {
            cancelStreaming()
        }
        conversations.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = conversations.first?.id
        }
        persistNow()
    }

    func updateSettings(id: String, model: String? = nil, reasoningEffort: String? = nil) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        if let model { conversations[index].model = model }
        if let reasoningEffort { conversations[index].reasoningEffort = reasoningEffort }
        schedulePersist()
    }

    // MARK: - Capabilities

    /// Capabilities differ per model on some providers — the reasoning levels
    /// and whether images are accepted both do on makora — so this is refetched
    /// whenever the selected model changes, not just at launch.
    func refreshCapabilities(client: BackendClient, model: String = "") async {
        // Retried because this typically fails while the backend is restarting,
        // and the answer gates the image guard: silently keeping "unknown" would
        // let an attachment through to a text-only model.
        for attempt in 0..<3 {
            do {
                capabilities = try await client.chatCapabilities(model: model)
                return
            } catch {
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
            }
        }
        // Keep the last known answer rather than blanking it — stale limits are
        // closer to the truth than "no limits at all".
        capabilities.ready = false
    }

    /// Fetches capabilities when the cached ones don't describe `model`.
    func ensureCapabilities(client: BackendClient, model: String) async {
        let wanted = model.isEmpty ? capabilities.defaultModel : model
        if !capabilities.model.isEmpty, capabilities.model == wanted {
            return
        }
        await refreshCapabilities(client: client, model: model)
    }

    // MARK: - Sending

    /// Appends the user turn and streams the reply into the same conversation.
    func send(
        conversationID: String,
        text: String,
        attachments: [ChatAttachment],
        client: BackendClient,
        systemPrompt: String
    ) {
        guard !isStreaming,
              let index = conversations.firstIndex(where: { $0.id == conversationID })
        else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        conversations[index].messages.append(
            .new(role: .user, text: trimmed, attachments: attachments)
        )
        touch(conversationID)

        // Re-read by id: `touch` re-sorts the array, so the index found above
        // can now point at a different conversation entirely.
        guard let conversation = conversation(id: conversationID) else { return }
        // A turn that failed is kept on screen — the user should see what went
        // wrong — but it holds no text, and a history with an empty turn in it
        // is rejected outright. One failed answer used to wedge the whole
        // conversation: every later message resent the empty turn and was
        // refused before it ever reached a provider.
        let wire = conversation.messages
            .filter { !$0.text.isEmpty || !$0.attachments.isEmpty }
            .map { message in
                BackendClient.ChatWireMessage(
                    role: message.role.rawValue,
                    content: message.text,
                    images: message.attachments.map(\.dataURL)
                )
            }

        streamingText = ""
        streamingConversationID = conversationID
        isStreaming = true
        startPublishing()

        streamTask = Task { [weak self] in
            guard let self else { return }
            var failure: String?
            do {
                for try await delta in client.chatStream(
                    messages: wire,
                    system: systemPrompt,
                    model: conversation.model,
                    reasoningEffort: conversation.reasoningEffort
                ) {
                    if Task.isCancelled { break }
                    self.streamingText += delta
                }
            } catch {
                failure = Self.message(for: error)
            }
            self.finishStreaming(conversationID: conversationID, failure: failure)
        }
    }

    func cancelStreaming() {
        guard isStreaming else { return }
        streamTask?.cancel()
        streamTask = nil
        // Whatever arrived before the cancel is worth keeping.
        finishStreaming(conversationID: streamingConversationID, failure: nil)
    }

    /// Drops the last assistant turn and re-asks with the same history.
    func regenerate(conversationID: String, client: BackendClient, systemPrompt: String) {
        guard !isStreaming,
              let index = conversations.firstIndex(where: { $0.id == conversationID }),
              let last = conversations[index].messages.last
        else { return }
        if last.role == .assistant {
            conversations[index].messages.removeLast()
        }
        guard let question = conversations[index].messages.last, question.role == .user else {
            return
        }
        conversations[index].messages.removeLast()
        send(
            conversationID: conversationID,
            text: question.text,
            attachments: question.attachments,
            client: client,
            systemPrompt: systemPrompt
        )
    }

    private func finishStreaming(conversationID: String?, failure: String?) {
        publishTask?.cancel()
        publishTask = nil
        streamTask = nil
        isStreaming = false

        let text = streamingText
        streamingText = ""
        streamingConversationID = nil

        guard let conversationID,
              let index = conversations.firstIndex(where: { $0.id == conversationID })
        else {
            streamTick &+= 1
            return
        }
        if !text.isEmpty || failure != nil {
            var message = ChatMessage.new(role: .assistant, text: text)
            message.error = failure
            conversations[index].messages.append(message)
        }
        touch(conversationID)
        streamTick &+= 1
    }

    private func startPublishing() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.streamPublishInterval)
                guard let self, !Task.isCancelled else { return }
                self.streamTick &+= 1
            }
        }
    }

    private func touch(_ id: String) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].updatedAt = Date.now.timeIntervalSince1970 * 1000
        conversations.sort { $0.updatedAt > $1.updatedAt }
        schedulePersist()
    }

    private static func message(for error: Error) -> String {
        if let backend = error as? BackendError {
            switch backend.code {
            case "LLM_UNAVAILABLE":
                return "LLM недоступна. Проверьте, что backend запущен с рабочим провайдером."
            case "LLM_BAD_RESPONSE":
                // The backend forwards the provider's own words — "model X is not
                // multimodal" is actionable in a way a generic message is not.
                return backend.message
            default:
                return backend.message
            }
        }
        return error.localizedDescription
    }

    // MARK: - Persistence

    /// Same shape as NotesStore: debounced, written off the main thread, and
    /// flushed synchronously before the app can quit.
    func flushPendingWrites() {
        if persistTask != nil {
            persistNow()
        }
        ioQueue.sync {}
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.persistDebounceNanos)
            guard !Task.isCancelled, let self else { return }
            self.persistNow()
        }
    }

    private func persistNow() {
        persistTask?.cancel()
        persistTask = nil
        let snapshot = conversations
        let url = storeURL
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            } catch {
                NSLog("Jerktionary: failed to persist chats: \(error)")
            }
        }
    }

    static func formatDate(_ millis: Double) -> String {
        NotesStore.formatDate(millis)
    }
}
