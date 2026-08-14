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
                Text("Создайте новый чат.")
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
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.lavenderGradient)
            Text("Выберите чат или создайте новый")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Новый чат", systemImage: "square.and.pencil") {
                chatStore.create()
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
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
        .accessibilityAddTraits(selected ? .isSelected : [])
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
    /// Attachments are real SwiftUI state: unlike the continuously changing
    /// text, they mutate rarely and must invalidate the empty composer on the
    /// very first image selection.
    @State private var attachments: [ChatAttachment] = []
    @State private var attachmentError: String?
    @State private var composerTextIsEmpty = true
    @State private var measuredComposerHeight: CGFloat = 0
    /// Set while the pre-send capability check is in flight, so a second Enter
    /// can't start the same message twice before streaming has begun.
    @State private var submitting = false

    private var conversation: Conversation? { chatStore.conversation(id: conversationID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
            drainPendingAttachments()
        }
        .onAppear {
            // When the shortcut changes the overlay from another pane to Chat,
            // the image can arrive before this composer exists. onChange cannot
            // observe a past mutation, so drain the handoff on mount as well.
            drainPendingAttachments()
        }
        .onChange(of: store.overlayMode) {
            // The hidden main window stays mounted behind the overlay. Recheck
            // ownership when the visible composer changes between windows.
            drainPendingAttachments()
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

    private func modelPicker(maxWidth: CGFloat) -> some View {
        Picker("Модель", selection: modelBinding) {
            Text(defaultModelLabel).tag("")
            ForEach(offeredModels, id: \.self) { model in
                Text(model).tag(model)
            }
        }
        .labelsHidden()
        .frame(minWidth: 120, maxWidth: maxWidth)
        .controlSize(.small)
        .help("Выбрать модель")
        .accessibilityLabel("Модель")
    }

    private var reasoningPicker: some View {
        Picker("Глубина рассуждения", selection: reasoningBinding) {
            Text("Глубина: по умолчанию").tag("")
            ForEach(chatStore.capabilities.reasoningLevels, id: \.self) { level in
                Text(Self.reasoningLabel(level)).tag(level)
            }
        }
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .help("Глубина рассуждения")
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
        return model.isEmpty ? "Модель по умолчанию" : "По умолчанию (\(model))"
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
        case "none": "Глубина: выкл"
        case "minimal": "Глубина: минимум"
        case "low": "Глубина: низкая"
        case "medium": "Глубина: средняя"
        case "high": "Глубина: высокая"
        // makora's own vocabulary: "max" above high, and gemma exposes a plain
        // on/off pair instead of a scale.
        case "max": "Глубина: максимум"
        case "enabled": "Глубина: вкл"
        default: "Глубина: \(level)"
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
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                if let status = composerStatus {
                    Label(status.message, systemImage: status.systemImage)
                        .font(.caption)
                        .foregroundStyle(status.color)
                        .lineLimit(compact ? 2 : 3)
                        .help(status.message)
                }

                if !attachments.isEmpty {
                    AttachmentStrip(
                        attachments: attachments,
                        compact: compact
                    ) { id in
                        attachments.removeAll { $0.id == id }
                    }
                }

                composerInput
            }
            .padding(compact ? 8 : 10)
            .background(
                Theme.tint.opacity(0.06),
                in: RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous)
            )
            // Dropping onto any part of the compound composer follows the same
            // path as the picker and paste.
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                load(providers)
                return true
            }

            if !compact, !chatStore.capabilities.ready {
                Text("Сервис чата недоступен — проверьте подключение в настройках")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var composerInput: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            ChatComposerTextView(
                documentID: conversationID,
                onEdit: { text in
                    draft.text = text
                    composerTextIsEmpty = text.isEmpty
                },
                onHeightChange: { measuredComposerHeight = $0 },
                onSubmit: submit,
                onPasteImages: add,
                onCaptureScreenshot: store.captureScreenshotToChat
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: composerHeight)

            ViewThatFits(in: .horizontal) {
                fullComposerControls
                compactComposerControls
            }
        }
    }

    private var fullComposerControls: some View {
        HStack(alignment: .center, spacing: 7) {
            attachmentButton
            modelPicker(maxWidth: compact ? 160 : 220)

            if !chatStore.capabilities.reasoningLevels.isEmpty {
                reasoningPicker
            }

            Spacer(minLength: 4)

            if !chatStore.isStreaming, conversation?.messages.isEmpty == false {
                regenerateButton
            }
            primaryComposerButton
        }
        .foregroundStyle(.secondary)
    }

    private var compactComposerControls: some View {
        HStack(alignment: .center, spacing: 7) {
            attachmentButton
            modelPicker(maxWidth: 150)
            Spacer(minLength: 0)

            if !chatStore.capabilities.reasoningLevels.isEmpty
                || (!chatStore.isStreaming && conversation?.messages.isEmpty == false) {
                Menu {
                    if !chatStore.capabilities.reasoningLevels.isEmpty {
                        Picker("Глубина рассуждения", selection: reasoningBinding) {
                            Text("По умолчанию").tag("")
                            ForEach(chatStore.capabilities.reasoningLevels, id: \.self) { level in
                                Text(Self.reasoningLabel(level)).tag(level)
                            }
                        }
                    }
                    if !chatStore.isStreaming, conversation?.messages.isEmpty == false {
                        Divider()
                        Button("Перегенерировать", systemImage: "arrow.counterclockwise") {
                            regenerate()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Параметры ответа")
                .accessibilityLabel("Параметры ответа")
            }

            primaryComposerButton
        }
        .foregroundStyle(.secondary)
    }

    private var attachmentButton: some View {
        Button {
            pickImages()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Theme.card.opacity(0.78), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Прикрепить изображение")
        .accessibilityLabel("Прикрепить изображение")
    }

    private var regenerateButton: some View {
        Button {
            regenerate()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Перегенерировать последний ответ")
        .accessibilityLabel("Перегенерировать последний ответ")
    }

    private var primaryComposerButton: some View {
        Button {
            if chatStore.isStreaming {
                chatStore.cancelStreaming()
            } else {
                submit()
            }
        } label: {
            Group {
                if chatStore.isStreaming {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                } else if submitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                }
            }
            .frame(width: 30, height: 30)
            .foregroundStyle(primaryActionHighlighted ? Color.white : Color.secondary)
            .background(primaryActionHighlighted ? Theme.tint : Theme.card.opacity(0.78), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!primaryActionAvailable)
        .help(chatStore.isStreaming ? "Остановить ответ" : "Отправить (Enter)")
        .accessibilityLabel(chatStore.isStreaming ? "Остановить ответ" : "Отправить")
    }

    private var primaryActionAvailable: Bool {
        chatStore.isStreaming || canSubmit
    }

    private var primaryActionHighlighted: Bool {
        chatStore.isStreaming || submitting || canSubmit
    }

    private var composerHeight: CGFloat {
        let minimum: CGFloat = compact ? 30 : 34
        let maximum: CGFloat = compact ? 72 : 120
        return min(max(measuredComposerHeight, minimum), maximum)
    }

    private var canSubmit: Bool {
        !chatStore.isStreaming
            && !submitting
            && (!composerTextIsEmpty || !attachments.isEmpty)
    }

    private var composerStatus: (message: String, systemImage: String, color: Color)? {
        if let attachmentError {
            return (attachmentError, "exclamationmark.circle.fill", .red)
        }
        if chatStore.capabilities.refusesImages, !attachments.isEmpty {
            return (
                "Модель \(chatStore.capabilities.model) не принимает изображения — выберите другую.",
                "exclamationmark.triangle.fill",
                .orange
            )
        }
        return nil
    }

    private func submit() {
        guard !chatStore.isStreaming, !submitting else { return }
        guard !attachments.isEmpty else {
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
            attachments: attachments,
            client: store.backendClient,
            systemPrompt: settings.chatSystemPrompt
        )
        draft.text = ""
        composerTextIsEmpty = true
        attachments = []
        attachmentError = nil
        NotificationCenter.default.post(name: .chatComposerShouldClear, object: conversationID)
    }

    // MARK: Attachments

    private func drainPendingAttachments() {
        // Both the normal chat and the overlay chat observe the same store even
        // while one window is hidden. Only the composer the user can see may
        // consume the handoff; otherwise the screenshot lands invisibly in the
        // background window and Ctrl+Shift+S appears to do nothing.
        guard compact == store.overlayMode else { return }
        guard !chatStore.pendingAttachments.isEmpty else { return }
        let pending = chatStore.pendingAttachments
        chatStore.pendingAttachments = []
        add(pending)
    }

    private func add(_ new: [ChatAttachment]) {
        guard !new.isEmpty else { return }
        let room = ChatImageLoader.maxPerMessage - attachments.count
        if room <= 0 {
            attachmentError = "Не больше \(ChatImageLoader.maxPerMessage) изображений в сообщении."
            return
        }
        attachmentError = nil
        attachments.append(contentsOf: new.prefix(room))
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            importImages(from: panel.urls)
        }

        // `runModal()` is unreliable while stealth mode makes the app an
        // accessory application and the overlay a non-activating NSPanel. A
        // sheet belongs to the window the user clicked, so it works without
        // changing activation policy or briefly revealing a Dock icon.
        if let presentingWindow = NSApp.keyWindow ?? WindowController.mainWindow {
            panel.beginSheetModal(for: presentingWindow, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func importImages(from urls: [URL]) {
        guard !urls.isEmpty else { return }
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
            if !message.attachments.isEmpty {
                AttachmentStrip(attachments: message.attachments, onRemove: nil)
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
        .padding(message.role == .user ? 12 : 0)
        .frame(maxWidth: message.role == .user ? 560 : .infinity, alignment: .leading)
        .background(
            message.role == .user ? Theme.tint.opacity(0.07) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .frame(
            maxWidth: .infinity,
            alignment: message.role == .user ? .trailing : .leading
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.role == .user ? "Ваше сообщение" : "Ответ ассистента")
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
            if !text.isEmpty {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Готовлю ответ…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Ассистент готовит ответ")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ответ ассистента")
    }
}

private struct AttachmentStrip: View {
    let attachments: [ChatAttachment]
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
