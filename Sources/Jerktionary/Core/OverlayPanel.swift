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

    private init() {}

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(contentProtected: Bool, opacity: Double, content: some View) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        panel.contentView = NSHostingView(rootView: AnyView(content))
        // Stealth applies here too: without it the card is the one part of the
        // app that would show up in a screen share.
        panel.sharingType = contentProtected ? .none : .readOnly
        panel.alphaValue = min(1, max(0.25, opacity))
        // Ordering front without activating keeps the current space in place.
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func setOpacity(_ opacity: Double) {
        panel?.alphaValue = min(1, max(0.25, opacity))
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

        positionTopRight(panel)
        return panel
    }

    /// Out of the way of what is usually being read, and clear of the menu bar.
    private func positionTopRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 24
        let size = WindowController.overlaySize
        panel.setFrame(
            NSRect(
                x: screen.visibleFrame.maxX - size.width - margin,
                y: screen.visibleFrame.maxY - size.height - margin,
                width: size.width,
                height: size.height
            ),
            display: false
        )
    }
}

/// A `.nonactivatingPanel` refuses key status by default, which would leave the
/// chat composer unable to receive a single keystroke.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
