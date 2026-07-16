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
            .fullContextAnswer: { [weak store] in store?.fullContextAnswer() }
        ])

        // Stealth by default, like the Electron app.
        WindowController.setContentProtection(true)
        WindowController.setTitle(store.settings.displayName)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.unregisterAll()
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
}
