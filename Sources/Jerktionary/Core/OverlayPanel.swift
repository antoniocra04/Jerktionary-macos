import AppKit
import SwiftUI

/// The compact card, hosted in its own floating panel rather than in the main
/// window.
///
/// A plain NSWindow cannot be shown over *another* app's full-screen space, no
/// matter its level: `.fullScreenAuxiliary` only covers windows accompanying
/// your own app's full-screen window. A non-activating `NSPanel` can, which is
/// the whole reason this exists separately from the main window.
///
/// Non-activating also matters on its own: clicking the card must not activate
/// the app, because activating would pull macOS back to the space the main
/// window lives on — exactly the jump this mode is meant to avoid.
@MainActor
final class OverlayPanel {
    static let shared = OverlayPanel()

    private var panel: NSPanel?
    /// The hosting view is kept and reused inside a plain container. Assigning a
    /// fresh NSHostingView as the panel's contentView lets Auto Layout resize
    /// the window to SwiftUI's fitting height, which grew the card to the full
    /// height of the screen on every toggle.
    private var host: NSHostingView<AnyView>?
    private weak var sizeKeeper: OverlayFrameKeeper?

    private init() {}

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(contentProtected: Bool, content: some View) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        if let host {
            host.rootView = AnyView(content)
        } else {
            let container = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
            let host = NSHostingView(rootView: AnyView(content))
            host.translatesAutoresizingMaskIntoConstraints = true
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            panel.contentView = container
            self.host = host
        }
        // Stealth applies here too: without it the card is the one part of the
        // app that would show up in a screen share.
        panel.sharingType = contentProtected ? .none : .readOnly
        // Ordering front without activating keeps the current space in place.
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func setContentProtection(_ enabled: Bool) {
        panel?.sharingType = enabled ? .none : .readOnly
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: WindowController.overlaySize),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        // Survives the app losing focus, which is the normal state during a call.
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.minSize = WindowController.overlayMinSize
        // A glance card, not a window: past this it stops being something you
        // read out of the corner of your eye.
        panel.maxSize = WindowController.overlayMaxSize

        let keeper = OverlayFrameKeeper()
        panel.delegate = keeper
        sizeKeeper = keeper
        objc_setAssociatedObject(panel, &OverlayFrameKeeper.key, keeper, .OBJC_ASSOCIATION_RETAIN)

        restoreFrame(panel)
        return panel
    }

    /// Where it was left, else centred near the top of the screen — close to
    /// where the eyes already are during a call, so glancing at it costs less of
    /// a head turn than a corner would.
    private func restoreFrame(_ panel: NSPanel) {
        let size = WindowController.overlaySize
        if let saved = OverlayFrameKeeper.savedFrame(minSize: WindowController.overlayMinSize),
           let normalized = normalizedFrame(saved, screens: NSScreen.screens) {
            panel.setFrame(normalized, display: false)
            return
        }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let topMargin: CGFloat = 12
        panel.setFrame(
            NSRect(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - topMargin,
                width: size.width,
                height: size.height
            ),
            display: false
        )
    }

    /// Keeps a restored card fully reachable after monitor removal, scaling or
    /// resolution changes. The title bar/drag surface can never land offscreen.
    private func normalizedFrame(_ frame: NSRect, screens: [NSScreen]) -> NSRect? {
        guard let screen = screens.max(by: {
            intersectionArea($0.visibleFrame, frame) < intersectionArea($1.visibleFrame, frame)
        }), intersectionArea(screen.visibleFrame, frame) > 0 else { return nil }

        let visible = screen.visibleFrame
        let minSize = WindowController.overlayMinSize
        let maxSize = WindowController.overlayMaxSize
        let width = min(max(frame.width, minSize.width), min(maxSize.width, visible.width))
        let height = min(max(frame.height, minSize.height), min(maxSize.height, visible.height))
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

}

/// Remembers where and how big the card was left. Stored as a string so it needs
/// nothing more than UserDefaults.
@MainActor
private final class OverlayFrameKeeper: NSObject, NSWindowDelegate {
    static var key: UInt8 = 0
    nonisolated static let defaultsKey = "settings.overlayFrame"

    nonisolated static func savedFrame(minSize: NSSize) -> NSRect? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        let rect = NSRectFromString(raw)
        guard rect.width.isFinite, rect.height.isFinite,
              rect.minX.isFinite, rect.minY.isFinite,
              rect.width >= minSize.width, rect.height >= minSize.height
        else { return nil }
        return rect
    }

    private func remember(_ window: NSWindow?) {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.defaultsKey)
    }

    func windowDidResize(_ notification: Notification) {
        remember(notification.object as? NSWindow)
    }

    func windowDidMove(_ notification: Notification) {
        remember(notification.object as? NSWindow)
    }
}

/// A `.nonactivatingPanel` refuses key status by default, which would leave the
/// chat composer unable to receive a single keystroke.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
