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
                    minWidth: WindowController.normalMinSize.width,
                    minHeight: WindowController.normalMinSize.height
                )
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Навигация") {
                Button(store.sidebarVisible ? "Скрыть историю встреч" : "Показать историю встреч") {
                    store.sidebarVisible.toggle()
                }
                .disabled(store.mainTab != .session)
                Divider()
                Button("Сессия") { store.mainTab = .session }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Заметки") { store.mainTab = .notes }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Чат") { store.mainTab = .chat }
                    .keyboardShortcut("3", modifiers: .command)
            }
            CommandMenu("Сессия") {
                Button("Ответить сейчас — Ctrl+Shift+Space") {
                    store.answerNow()
                }
                .disabled(store.currentText.isEmpty || store.answers.isGenerating)
                Button("Ответить с полным контекстом — Ctrl+Shift+Enter") {
                    store.fullContextAnswer()
                }
                .disabled(store.currentText.isEmpty || store.answers.isGenerating)
                if store.answers.isGenerating {
                    Button("Остановить ответ") { store.cancelAnswer() }
                }
                Divider()
                Button(store.isListening ? "Остановить прослушивание" : "Начать прослушивание") {
                    Task { await store.toggleListening() }
                }
                .disabled(!store.isListening && (!store.backendReady || store.backendUnavailable))
                Divider()
                Button("Компактный режим") {
                    store.toggleOverlay()
                }
                Button(store.contentProtectionEnabled
                       ? "Показывать при захвате экрана"
                       : "Скрыть при захвате экрана") {
                    store.contentProtectionEnabled.toggle()
                    WindowController.setContentProtection(store.contentProtectionEnabled)
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(store.chats)
                .preferredColorScheme(settings.theme.colorScheme)
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

        let failed = hotkeys.register([
            .answerNow: { [weak store] in store?.answerNow() },
            .toggleOverlay: { [weak store] in store?.toggleOverlay() },
            .fullContextAnswer: { [weak store] in store?.fullContextAnswer() },
            .screenshotToChat: { [weak store] in store?.captureScreenshotToChat() }
        ])
        if !failed.isEmpty {
            store.showNotice("Некоторые глобальные сочетания клавиш недоступны")
        }

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
            store?.meetings.flushPendingWrites()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
