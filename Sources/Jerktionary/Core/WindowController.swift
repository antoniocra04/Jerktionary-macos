import AppKit
import Foundation

/// Direct NSWindow manipulation for features SwiftUI has no API for:
/// content protection (exclude from screen capture), the compact always-on-top
/// overlay mode, and the masked window title.
@MainActor
enum WindowController {
    static let overlaySize = NSSize(width: 520, height: 360)
    static let overlayMinSize = NSSize(width: 360, height: 280)
    static let overlayMaxSize = NSSize(width: 900, height: 700)
    static let normalMinSize = NSSize(width: 1024, height: 680)

    /// Never the overlay panel: it is a separate window and must not receive
    /// the main window's title, stealth or sizing.
    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
            ?? NSApp.windows.first { !($0 is NSPanel) }
    }

    /// Hidden while the compact card is up, so the two never overlap.
    static func setMainWindowVisible(_ visible: Bool) {
        guard let window = mainWindow else { return }
        if visible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderOut(nil)
        }
    }

    /// Stealth: exclude the window from screen capture / sharing. The user still
    /// sees it locally — port of Electron setContentProtection.
    static func setContentProtection(_ enabled: Bool) {
        mainWindow?.sharingType = enabled ? .none : .readOnly
        OverlayPanel.shared.setContentProtection(enabled)
        setDockIconHidden(enabled)
    }

    /// Stealth also hides the Dock icon (accessory activation policy), so a
    /// shared screen doesn't reveal the app in the Dock. Re-activating keeps
    /// the window key after the policy switch.
    static func setDockIconHidden(_ hidden: Bool) {
        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
        DispatchQueue.main.async {
            // Not while the compact card is up: bringing the main window back
            // would undo the mode and yank the user to its space.
            guard !OverlayPanel.shared.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    static func setTitle(_ title: String) {
        let value = title.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        mainWindow?.title = value
    }

}
