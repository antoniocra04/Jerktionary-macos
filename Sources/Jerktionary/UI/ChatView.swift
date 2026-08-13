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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var conversations: [Conversation] { chatStore.conversations }
    private var selectedID: String? { chatStore.selectedID }

    var body: some View {
        HSplitView {
            conversationList
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                .padding(.trailing, 8)

            Group {
                if let selectedID, chatStore.conversation(id: selectedID) != nil {
                    ChatThreadView(conversationID: selectedID)
                        .id(selectedID)
                } else {
                    emptyState
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 8)
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 28)
        .task {
            await chatStore.refreshCapabilities(client: store.backendClient)
        }
        .onAppear {
            if selectedID == nil || chatStore.conversation(id: selectedID ?? "") == nil {
                chatStore.selectedID = conversations.first?.id
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
                    chatStore.create()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tint)
                .help("Новый чат")
                .accessibilityLabel("Новый чат")
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
                                chatStore.selectedID = conversation.id
                            } onDelete: {
                                chatStore.delete(conversation.id)
                            }
                        }
                    }
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.2),
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
    @State private var confirmingDelete = false

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
            Button("Удалить", role: .destructive) {
                confirmingDelete = true
            }
        }
        .alert("Удалить чат?", isPresented: $confirmingDelete) {
            Button("Удалить", role: .destructive, action: onDelete)
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Историю этого чата нельзя будет восстановить.")
        }
    }
}

/// The draft of the message being composed, held outside SwiftUI's state graph
/// for the same reason the note body is: pushing a growing string through
/// `@State` on every keystroke costs time proportional to its length.
@MainActor
final class ComposerDraft {
    var text = ""
    var attachments: [ChatAttachment] = []
}

/// Also used by the compact overlay, which shows the thread on its own.
struct ChatThreadView: View {
    @EnvironmentObject private var chatStore: ChatStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: AppStore
    let conversationID: String
    /// Set by the overlay, where the card is ~360pt tall: the full-size chrome
    /// (its own card inset, a tall composer, the keyboard hint) would leave the
    /// thread itself almost no room.
    var compact = false

    @State private var draft = ComposerDraft()
    /// Bumped when the attachment strip must redraw; the text itself never does.
    @State private var attachmentTick = 0
    @State private var attachmentError: String?
    /// Set while the pre-send capability check is in flight, so a second Enter
    /// can't start the same message twice before streaming has begun.
    @State private var submitting = false

    private var conversation: Conversation? { chatStore.conversation(id: conversationID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            thread
            composer
        }
        .padding(compact ? 0 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            compact ? AnyShapeStyle(.clear) : AnyShapeStyle(Theme.card),
            in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        )
        .shadow(color: compact ? .clear : Theme.shadowColor, radius: 6, y: 1)
        .frame(maxWidth: compact ? 680 : .infinity)
        .onChange(of: chatStore.pendingAttachments) {
            // Handed over by the screenshot hotkey, which has no access to the
            // draft; taking them here keeps one owner for the composer state.
            guard !chatStore.pendingAttachments.isEmpty else { return }
            add(chatStore.pendingAttachments)
            chatStore.pendingAttachments = []
        }
        .onChange(of: chatStore.transientError) {
            if let message = chatStore.transientError {
                attachmentError = message
                chatStore.transientError = nil
            }
        }
        .onChange(of: attachmentError) {
            if let attachmentError {
                AccessibilityAnnouncer.announce(attachmentError)
            }
        }
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
        ViewThatFits(in: .horizontal) {
            fullHeader
            compactHeader
        }
    }

    private var fullHeader: some View {
        HStack(spacing: 10) {
            modelPicker(maxWidth: compact ? 190 : 260)

            if !chatStore.capabilities.reasoningLevels.isEmpty {
                reasoningPicker
            }

            Spacer()
            streamAction
        }
        .foregroundStyle(.secondary)
    }

    private var compactHeader: some View {
        HStack(spacing: 8) {
            modelPicker(maxWidth: 190)
            Spacer(minLength: 0)
            if chatStore.isStreaming, chatStore.streamingConversationID == conversationID {
                streamAction
            } else {
                Menu {
                    if !chatStore.capabilities.reasoningLevels.isEmpty {
                        reasoningPicker
                    }
                    if conversation?.messages.isEmpty == false {
                        Button("Перегенерировать", systemImage: "arrow.counterclockwise") {
                            regenerate()
                        }
                    }
                } label: {
                    Label("Параметры чата", systemImage: "ellipsis.circle")
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Параметры чата")
            }
        }
        .foregroundStyle(.secondary)
    }

    private func modelPicker(maxWidth: CGFloat) -> some View {
        Picker("Модель", selection: modelBinding) {
            Text(defaultModelLabel).tag("")
            ForEach(offeredModels, id: \.self) { model in
                Text(model).tag(model)
            }
        }
        .labelsHidden()
        .frame(minWidth: 120, maxWidth: maxWidth)
        .controlSize(compact ? .small : .regular)
        .help("Модель. Список задаётся в настройках.")
    }

    private var reasoningPicker: some View {
        Picker("Мощность ризонинга", selection: reasoningBinding) {
            Text("Ризонинг: по умолчанию").tag("")
            ForEach(chatStore.capabilities.reasoningLevels, id: \.self) { level in
                Text(Self.reasoningLabel(level)).tag(level)
            }
        }
        .labelsHidden()
        .fixedSize()
        .controlSize(compact ? .small : .regular)
        .help("Мощность ризонинга")
    }

    @ViewBuilder
    private var streamAction: some View {
        if chatStore.isStreaming, chatStore.streamingConversationID == conversationID {
            Button("Стоп", systemImage: "stop.fill") {
                chatStore.cancelStreaming()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        } else if conversation?.messages.isEmpty == false {
            Button("Перегенерировать", systemImage: "arrow.counterclockwise") {
                regenerate()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    private func regenerate() {
        chatStore.regenerate(
            conversationID: conversationID,
            client: store.backendClient,
            systemPrompt: settings.chatSystemPrompt
        )
    }

    /// What the provider is known to serve, plus anything hand-added in
    /// settings. Deduplicated, provider order first.
    private var offeredModels: [String] {
        var seen = Set<String>()
        return (chatStore.capabilities.models + settings.chatModels)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
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
        // makora's own vocabulary: "max" above high, and gemma exposes a plain
        // on/off pair instead of a scale.
        case "max": "Ризонинг: максимум"
        case "enabled": "Ризонинг: вкл"
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
            .onAppear {
                // Opening on the oldest message hid the newest below the fold.
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
                    .lineLimit(compact ? 2 : nil)
                    .help(attachmentError)
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
                AttachmentStrip(
                    attachments: draft.attachments,
                    tick: attachmentTick,
                    compact: compact
                ) { id in
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
                .foregroundStyle(.secondary)
                .help("Прикрепить изображение")
                .accessibilityLabel("Прикрепить изображение")

                ChatComposerTextView(
                    documentID: conversationID,
                    onEdit: { draft.text = $0 },
                    onSubmit: submit,
                    onPasteImages: add
                )
                .frame(minHeight: compact ? 26 : 34, maxHeight: compact ? 72 : 120)

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
                .accessibilityLabel("Отправить")
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

            if !compact {
                Text(chatStore.capabilities.ready
                     ? "Enter — отправить, Shift+Enter — перенос строки"
                     : "LLM на backend недоступна — проверьте статус в настройках")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func submit() {
        guard !chatStore.isStreaming, !submitting else { return }
        guard !draft.attachments.isEmpty else {
            performSend()
            return
        }
        // The guard is only as good as the capabilities behind it, and the first
        // fetch races a backend that may still be starting. Confirm before
        // sending; when they are already known this returns without a request.
        submitting = true
        Task {
            defer { submitting = false }
            await chatStore.ensureCapabilities(
                client: store.backendClient,
                model: conversation?.model ?? ""
            )
            if chatStore.capabilities.refusesImages {
                attachmentError =
                    "Модель \(chatStore.capabilities.model) работает только с текстом. Уберите изображения или смените модель."
                return
            }
            performSend()
        }
    }

    private func performSend() {
        chatStore.send(
            conversationID: conversationID,
            text: draft.text,
            attachments: draft.attachments,
            client: store.backendClient,
            systemPrompt: settings.chatSystemPrompt
        )
        draft.text = ""
        draft.attachments = []
        attachmentError = nil
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
        let urls = panel.urls
        Task {
            do {
                let attachments = try await Task.detached(priority: .userInitiated) {
                    try urls.map { try ChatImageLoader.attachment(fromFile: $0) }
                }.value
                add(attachments)
            } catch {
                attachmentError = error.localizedDescription
            }
        }
    }

    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadDataRepresentation(for: .image) { data, _ in
                guard let data, let image = NSImage(data: data),
                      let attachment = ChatImageLoader.attachment(from: image, name: "Вставка")
                else { return }
                Task { @MainActor [attachment] in
                    add([attachment])
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
    var compact = false
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
                                .frame(width: compact ? 44 : 72, height: compact ? 44 : 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .accessibilityLabel("Изображение: \(attachment.name)")
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
                            .accessibilityLabel("Удалить изображение \(attachment.name)")
                        }
                    }
                    .help(attachment.name)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollContentBackground(.hidden)
        .frame(height: compact ? 52 : 80)
    }
}

extension Notification.Name {
    static let chatComposerShouldClear = Notification.Name("chatComposerShouldClear")
}
