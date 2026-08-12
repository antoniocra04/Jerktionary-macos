import AppKit
import Foundation

/// Direct NSWindow manipulation for features SwiftUI has no API for:
/// content protection (exclude from screen capture), the compact always-on-top
/// overlay mode, and the masked window title.
@MainActor
enum WindowController {
    static let overlaySize = NSSize(width: 520, height: 360)
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

    /// Compact translucent card that floats over everything, on every space and
    /// over other apps' full-screen windows — the state to be in during a call.
    ///
    /// `.screenSaver` outranks full-screen windows, but a level alone is not
    /// enough: without `.fullScreenAuxiliary` the window is hidden when another
    /// app goes full screen, and without `.stationary` it slides away with a
    /// space switch. The background is cleared so SwiftUI can draw a translucent
    /// material into it, which also means the card has to be draggable by its
    /// body — there is no title bar left to grab.
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
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary])
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isMovableByWindowBackground = true
        } else {
            window.level = .normal
            window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary, .stationary])
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.hasShadow = true
            window.isMovableByWindowBackground = false
            window.alphaValue = 1
            window.minSize = normalMinSize
            if let savedFrame {
                window.setFrame(savedFrame, display: true, animate: false)
            }
            savedFrame = nil
        }
    }

    /// Overall transparency of the compact card, including its text — the point
    /// is to see through it, so a translucent background alone isn't enough.
    /// Clamped: fully invisible would be a window that can't be found again.
    static func setOverlayOpacity(_ opacity: Double) {
        mainWindow?.alphaValue = min(1, max(0.25, opacity))
    }
}
