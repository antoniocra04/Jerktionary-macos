import AppKit
import Foundation

/// Direct NSWindow manipulation for features SwiftUI has no API for:
/// content protection (exclude from screen capture), the compact always-on-top
/// overlay mode, and the masked window title.
@MainActor
enum WindowController {
    static let overlaySize = NSSize(width: 460, height: 320)
    static let overlayMinSize = NSSize(width: 360, height: 220)
    static let normalMinSize = NSSize(width: 1024, height: 680)

    private static var savedFrame: NSRect?

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && !($0 is NSPanel) } ?? NSApp.windows.first
    }

    /// Stealth: exclude the window from screen capture / sharing. The user still
    /// sees it locally — port of Electron setContentProtection.
    static func setContentProtection(_ enabled: Bool) {
        mainWindow?.sharingType = enabled ? .none : .readOnly
        setDockIconHidden(enabled)
    }

    /// Stealth also hides the Dock icon (accessory activation policy), so a
    /// shared screen doesn't reveal the app in the Dock. Re-activating keeps
    /// the window key after the policy switch.
    static func setDockIconHidden(_ hidden: Bool) {
        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    static func setTitle(_ title: String) {
        let value = title.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        mainWindow?.title = value
    }

    /// Compact always-on-top card for use during a call. `.screenSaver` level
    /// keeps it above full-screen call windows too.
    static func setOverlayMode(_ enabled: Bool) {
        guard let window = mainWindow else { return }
        if enabled {
            savedFrame = window.frame
            window.minSize = overlayMinSize
            var frame = window.frame
            frame.origin.y += frame.height - overlaySize.height
            frame.size = overlaySize
            window.setFrame(frame, display: true, animate: false)
            window.level = .screenSaver
            window.collectionBehavior.insert(.canJoinAllSpaces)
        } else {
            window.level = .normal
            window.collectionBehavior.remove(.canJoinAllSpaces)
            window.minSize = normalMinSize
            if let savedFrame {
                window.setFrame(savedFrame, display: true, animate: false)
            }
            savedFrame = nil
        }
    }
}
