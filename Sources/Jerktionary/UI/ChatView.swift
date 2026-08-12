import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Conversation list on the left, thread and composer on the right.
///
/// Observes ChatStore directly rather than reaching through AppStore: all three
/// tabs stay mounted, so an AppStore subscription would re-render the whole
/// thread on every transcript update behind the scenes.
struct ChatView: View {
    @EnvironmentObject private var chatStore: ChatStore
    @EnvironmentObject private var store: AppStore
    @State private var selectedID: String?

    private var conversations: [Conversation] { chatStore.conversations }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            conversationList
                .frame(width: 260)

            Group {
                if let selectedID, chatStore.conversation(id: selectedID) != nil {
                    ChatThreadView(conversationID: selectedID)
                        .id(selectedID)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 28)
        .padding(.top, 4)
        .padding(.bottom, 28)
        .task {
            await chatStore.refreshCapabilities(client: store.backendClient)
        }
        .onAppear {
            if selectedID == nil || chatStore.conversation(id: selectedID ?? "") == nil {
                selectedID = conversations.first?.id
            }
        }
    }

    private var conversationList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Чаты")
                    .font(.headline)
                Spacer()
                Button {
                    selectedID = chatStore.create().id
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tint)
                .help("Новый чат")
            }

            if conversations.isEmpty {
                Text("Чатов пока нет. Нажмите ✎, чтобы начать.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(conversations) { conversation in
                            ConversationRow(
                                conversation: conversation,
                                selected: conversation.id == selectedID
                            ) {
                                selectedID = conversation.id
                            } onDelete: {
                                chatStore.delete(conversation.id)
                                if selectedID == conversation.id {
                                    selectedID = chatStore.conversations.first?.id
                                }
                            }
                        }
                    }
                    .animation(
                        .spring(response: 0.35, dampingFraction: 0.8),
                        value: conversations.map(\.id)
                    )
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.lavenderGradient)
            Text("Выберите чат или создайте новый")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !chatStore.capabilities.label.isEmpty {
                Text("Провайдер: \(chatStore.capabilities.label)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let selected: Bool
    let open: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(ChatStore.formatDate(conversation.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? Theme.tint.opacity(0.14) : (hovering ? Theme.tint.opacity(0.07) : .clear),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Удалить", role: .destructive, action: onDelete)
        }
    }
}

/// The draft of the message being composed, held outside SwiftUI's state graph
/// for the same reason the note body is: pushing a growing string through
/// `@State` on every keystroke costs time proportional to its length.
@MainActor
private final class ComposerDraft {
    var text = ""
    var attachments: [ChatAttachment] = []
}

private struct ChatThreadView: View {
    @EnvironmentObject private var chatStore: ChatStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: AppStore
    let conversationID: String

    @State private var draft = ComposerDraft()
    /// Bumped when the attachment strip must redraw; the text itself never does.
    @State private var attachmentTick = 0
    @State private var attachmentError: String?

    private var conversation: Conversation? { chatStore.conversation(id: conversationID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            thread
            composer
        }
        .journalCard(padding: 18)
        .task(id: conversation?.model ?? "") {
            await chatStore.refreshCapabilities(
                client: store.backendClient,
                model: conversation?.model ?? ""
            )
            // A level valid for the previous model may not exist on this one, and
            // sending an unknown effort fails the whole request.
            let levels = chatStore.capabilities.reasoningLevels
            if let current = conversation?.reasoningEffort,
               !current.isEmpty, !levels.contains(current) {
                chatStore.updateSettings(id: conversationID, reasoningEffort: "")
            }
        }
    }

    // MARK: Header — model and reasoning

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: modelBinding) {
                Text(defaultModelLabel).tag("")
                ForEach(settings.chatModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            .help("Модель. Список задаётся в настройках.")

            if !chatStore.capabilities.reasoningLevels.isEmpty {
                Picker("", selection: reasoningBinding) {
                    Text("Ризонинг: по умолчанию").tag("")
                    ForEach(chatStore.capabilities.reasoningLevels, id: \.self) { level in
                        Text(Self.reasoningLabel(level)).tag(level)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Мощность ризонинга")
            }

            Spacer()

            if chatStore.isStreaming, chatStore.streamingConversationID == conversationID {
                Button("Стоп", systemImage: "stop.fill") {
                    chatStore.cancelStreaming()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else if conversation?.messages.isEmpty == false {
                Button("Перегенерировать", systemImage: "arrow.counterclockwise") {
                    chatStore.regenerate(
                        conversationID: conversationID,
                        client: store.backendClient,
                        systemPrompt: settings.chatSystemPrompt
                    )
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var defaultModelLabel: String {
        let model = chatStore.capabilities.defaultModel
        return model.isEmpty ? "Модель backend" : "По умолчанию (\(model))"
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { conversation?.model ?? "" },
            set: { chatStore.updateSettings(id: conversationID, model: $0) }
        )
    }

    private var reasoningBinding: Binding<String> {
        Binding(
            get: { conversation?.reasoningEffort ?? "" },
            set: { chatStore.updateSettings(id: conversationID, reasoningEffort: $0) }
        )
    }

    private static func reasoningLabel(_ level: String) -> String {
        switch level {
        case "none": "Ризонинг: выкл"
        case "minimal": "Ризонинг: минимум"
        case "low": "Ризонинг: низкий"
        case "medium": "Ризонинг: средний"
        case "high": "Ризонинг: высокий"
        default: "Ризонинг: \(level)"
        }
    }

    // MARK: Thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(conversation?.messages ?? []) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if chatStore.isStreaming, chatStore.streamingConversationID == conversationID {
                        StreamingBubble(text: chatStore.streamingText, tick: chatStore.streamTick)
                            .id("streaming")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: chatStore.streamTick) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: conversation?.messages.count ?? 0) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if chatStore.capabilities.refusesImages, !draft.attachments.isEmpty {
                Label(
                    "Модель \(chatStore.capabilities.model) не принимает изображения — выберите другую в списке моделей.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !draft.attachments.isEmpty {
                AttachmentStrip(attachments: draft.attachments, tick: attachmentTick) { id in
                    draft.attachments.removeAll { $0.id == id }
                    attachmentTick &+= 1
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    pickImages()
                } label: {
                    Image(systemName: "photo.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tint)
                .help("Прикрепить изображение")

                ChatComposerTextView(
                    documentID: conversationID,
                    onEdit: { draft.text = $0 },
                    onSubmit: submit,
                    onPasteImages: add
                )
                .frame(minHeight: 34, maxHeight: 120)

                Button {
                    submit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .foregroundStyle(chatStore.isStreaming ? Color.secondary : Theme.tint)
                .disabled(chatStore.isStreaming)
                .help("Отправить (Enter)")
            }
            .padding(10)
            .background(
                Theme.tint.opacity(0.06),
                in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous)
            )
            // Dropping onto the composer is the same path as the picker and paste.
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                load(providers)
                return true
            }

            Text(chatStore.capabilities.ready
                 ? "Enter — отправить, Shift+Enter — перенос строки"
                 : "LLM на backend недоступна — проверьте статус в настройках")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func submit() {
        if chatStore.capabilities.refusesImages, !draft.attachments.isEmpty {
            attachmentError =
                "Модель \(chatStore.capabilities.model) работает только с текстом. Уберите изображения или смените модель."
            return
        }
        chatStore.send(
            conversationID: conversationID,
            text: draft.text,
            attachments: draft.attachments,
            client: store.backendClient,
            systemPrompt: settings.chatSystemPrompt
        )
        draft.text = ""
        draft.attachments = []
        attachmentTick &+= 1
        NotificationCenter.default.post(name: .chatComposerShouldClear, object: conversationID)
    }

    // MARK: Attachments

    private func add(_ new: [ChatAttachment]) {
        guard !new.isEmpty else { return }
        let room = ChatImageLoader.maxPerMessage - draft.attachments.count
        if room <= 0 {
            attachmentError = "Не больше \(ChatImageLoader.maxPerMessage) изображений в сообщении."
            return
        }
        attachmentError = nil
        draft.attachments.append(contentsOf: new.prefix(room))
        attachmentTick &+= 1
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        guard panel.runModal() == .OK else { return }
        do {
            add(try panel.urls.map { try ChatImageLoader.attachment(fromFile: $0) })
        } catch {
            attachmentError = error.localizedDescription
        }
    }

    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadDataRepresentation(for: .image) { data, _ in
                guard let data, let image = NSImage(data: data) else { return }
                Task { @MainActor in
                    if let attachment = ChatImageLoader.attachment(from: image, name: "Вставка") {
                        add([attachment])
                    }
                }
            }
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == .user ? "Вы" : "Ассистент")
                .font(.caption.weight(.semibold))
                .foregroundStyle(message.role == .user ? Color.secondary : Theme.tint)

            if !message.attachments.isEmpty {
                AttachmentStrip(attachments: message.attachments, tick: 0, onRemove: nil)
            }

            if let error = message.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !message.text.isEmpty {
                if message.role == .assistant {
                    MarkdownView(text: message.text)
                        .textSelection(.enabled)
                } else {
                    Text(message.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            message.role == .user ? Theme.tint.opacity(0.07) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

/// The in-flight answer. Rendered as plain text rather than Markdown: reparsing
/// a growing document on every publish is the cost this whole design avoids —
/// the finished message becomes Markdown once it lands in the conversation.
private struct StreamingBubble: View {
    let text: String
    let tick: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Ассистент")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.tint)
                ProgressView().controlSize(.small)
            }
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

private struct AttachmentStrip: View {
    let attachments: [ChatAttachment]
    let tick: Int
    var onRemove: ((String) -> Void)?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        if let image = attachment.image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        if let onRemove {
                            Button {
                                onRemove(attachment.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .padding(3)
                        }
                    }
                    .help(attachment.name)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollContentBackground(.hidden)
        .frame(height: 80)
    }
}

extension Notification.Name {
    static let chatComposerShouldClear = Notification.Name("chatComposerShouldClear")
}
