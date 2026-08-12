import SwiftUI

@main
struct JerktionaryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings: AppSettings
    @StateObject private var store: AppStore

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: AppStore(settings: settings))
    }

    var body: some Scene {
        Window("Jerktionary", id: "main") {
            RootView()
                .environmentObject(settings)
                .environmentObject(store)
                // The nested stores are injected in their own right: views that
                // read them need to observe them, not rely on AppStore churn to
                // be re-rendered.
                .environmentObject(store.notes)
                .environmentObject(store.chats)
                .environmentObject(store.meetings)
                .environmentObject(store.answers)
                .environmentObject(store.explanations)
                .onAppear {
                    appDelegate.configure(store: store)
                }
                .preferredColorScheme(settings.theme.colorScheme)
                .frame(
                    minWidth: store.overlayMode ? WindowController.overlayMinSize.width : WindowController.normalMinSize.width,
                    minHeight: store.overlayMode ? WindowController.overlayMinSize.height : WindowController.normalMinSize.height
                )
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeys = GlobalHotkeys()
    private var store: AppStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Without an explicit .regular policy a bare SPM binary (swift run /
        // Xcode's run of the executable product) is treated as a background
        // process: its windows render but never become key, so text fields
        // can't receive typing.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    func configure(store: AppStore) {
        guard self.store == nil else { return }
        self.store = store

        hotkeys.register([
            .answerNow: { [weak store] in store?.answerNow() },
            .toggleOverlay: { [weak store] in store?.toggleOverlay() },
            .fullContextAnswer: { [weak store] in store?.fullContextAnswer() },
            .screenshotToChat: { [weak store] in store?.captureScreenshotToChat() }
        ])

        // Stealth by default, like the Electron app.
        WindowController.setContentProtection(true)
        WindowController.setTitle(store.settings.displayName)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.unregisterAll()
        // Backstop for the editor's own flush: notes are written on a debounce
        // off the main thread, and nothing else waits for that write.
        MainActor.assumeIsolated {
            store?.notes.flushPendingWrites()
            store?.chats.flushPendingWrites()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension AppStore {
    func toggleOverlay() {
        overlayMode.toggle()
        WindowController.setOverlayMode(overlayMode)
    }

    /// Ctrl+Shift+S: pick a region of the screen and put it in the chat.
    ///
    /// Auto-sends only when a screenshot prompt is configured — an image with no
    /// question is a wasted request — and never when the selected model can't
    /// read images, in which case it is left in the composer with the warning
    /// the chat tab already shows.
    func captureScreenshotToChat() {
        Task { @MainActor in
            let attachment: ChatAttachment?
            do {
                attachment = try await ScreenshotCapture.captureRegion()
            } catch {
                chats.transientError = error.localizedDescription
                mainTab = .chat
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            guard let attachment else { return } // selection cancelled

            let conversation = chats.currentOrNewConversation()
            mainTab = .chat
            NSApp.activate(ignoringOtherApps: true)

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
