import AppKit
import SwiftUI

/// Actions the global hotkeys and toolbar trigger on the store. Kept out of the
/// @main file so they can be exercised without standing up the whole app.
extension AppStore {
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
                opacity: settings.overlayOpacity,
                content: OverlayView()
                    .environmentObject(settings)
                    .environmentObject(self)
                    .environmentObject(chats)
                    .environmentObject(notes)
                    .environmentObject(meetings)
                    .environmentObject(answers)
                    .environmentObject(explanations)
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
