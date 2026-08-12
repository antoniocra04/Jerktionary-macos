import AppKit
import SwiftUI

/// Actions the global hotkeys and toolbar trigger on the store. Kept out of the
/// @main file so they can be exercised without standing up the whole app.
/// What the overlay's status light means. The old dot was `isListening`, which
/// made a dead microphone and "nobody has spoken yet" the same grey.
enum OverlayStatus: Equatable {
    case fault
    case hearing
    case listening
    case idle

    var color: Color {
        switch self {
        case .fault: .orange
        case .hearing: .green
        case .listening: Color.green.opacity(0.55)
        case .idle: Color.secondary.opacity(0.35)
        }
    }

    var label: String {
        switch self {
        case .fault: "Сбой — подробности в карточке"
        case .hearing: "Слышу голос"
        case .listening: "Слушаю, тихо"
        case .idle: "Распознавание выключено"
        }
    }
}

extension AppStore {
    /// One line the overlay can show when something is actually broken. Its
    /// absence used to be indistinguishable from a quiet call.
    var overlayFault: String? {
        if let error = microphoneError ?? websocketError { return error }
        if backendStatusLoaded, backendUnavailable {
            return "Backend недоступен — ответы не придут. Проверьте, что он запущен."
        }
        if backendStatusLoaded, !backendReady {
            return "Backend запущен, но не готов отвечать."
        }
        if isListening, connectionStatus == .error {
            return "Нет связи с распознаванием."
        }
        return nil
    }

    var overlayStatus: OverlayStatus {
        if overlayFault != nil { return .fault }
        guard isListening else { return .idle }
        return audioLevel.level > 0.04 ? .hearing : .listening
    }

    /// Hides the card without un-hiding the main window. The expand button
    /// summons a 1024pt window, which is the wrong answer to "make it go away"
    /// on a tool whose whole point is not being seen.
    func hideOverlay() {
        overlayMode = false
        OverlayPanel.shared.hide()
    }

    func toggleOverlay() {
        overlayMode.toggle()
        applyOverlayMode()
    }

    /// The card lives in its own panel, so switching modes swaps which of the
    /// two is on screen rather than reskinning one window.
    func applyOverlayMode() {
        if overlayMode {
            OverlayPanel.shared.show(
                contentProtected: contentProtectionEnabled,
                content: OverlayView()
                    .environmentObject(settings)
                    .environmentObject(self)
                    .environmentObject(chats)
                    .environmentObject(notes)
                    .environmentObject(meetings)
                    .environmentObject(answers)
                    .environmentObject(explanations)
                    .environmentObject(audioLevel)
                    .preferredColorScheme(settings.theme.colorScheme)
            )
            WindowController.setMainWindowVisible(false)
        } else {
            OverlayPanel.shared.hide()
            WindowController.setMainWindowVisible(true)
        }
    }

    /// Ctrl+Shift+S: grab the screen into the chat without showing anything.
    ///
    /// Nothing is brought forward and no window is touched — the whole point is
    /// that pressing this looks like nothing happened. The answer is waiting in
    /// the Chat tab (or the overlay) whenever it's convenient to look.
    ///
    /// Auto-sends only when a screenshot prompt is configured: with the app
    /// staying in the background there is no chance to type a question, but
    /// sending an image without one wastes the request. Never auto-sends to a
    /// model that reports it cannot read images — that shot waits in the
    /// composer with the warning the chat tab already shows.
    func captureScreenshotToChat() {
        Task { @MainActor in
            let attachment: ChatAttachment
            do {
                attachment = try await ScreenshotCapture.captureScreen()
            } catch {
                chats.transientError = error.localizedDescription
                return
            }

            let conversation = chats.currentOrNewConversation()
            mainTab = .chat

            let prompt = settings.chatScreenshotPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else {
                chats.pendingAttachments.append(attachment)
                return
            }

            await chats.ensureCapabilities(client: backendClient, model: conversation.model)
            guard !chats.capabilities.refusesImages else {
                chats.pendingAttachments.append(attachment)
                return
            }
            chats.send(
                conversationID: conversation.id,
                text: prompt,
                attachments: [attachment],
                client: backendClient,
                systemPrompt: settings.chatSystemPrompt
            )
        }
    }
}
