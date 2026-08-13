import Carbon.HIToolbox
import Foundation

/// Carbon-based global hotkeys (work while other apps are focused, no
/// Accessibility permission needed):
///   Ctrl+Shift+Space — answer now
///   Ctrl+Shift+O     — toggle overlay
///   Ctrl+Shift+Enter — full-context answer
///   Ctrl+Shift+S     — screenshot a region into the chat
final class GlobalHotkeys {
    enum Action: UInt32, CaseIterable {
        case answerNow = 1
        case toggleOverlay = 2
        case fullContextAnswer = 3
        case screenshotToChat = 4

        var keyCode: UInt32 {
            switch self {
            case .answerNow: UInt32(kVK_Space)
            case .toggleOverlay: UInt32(kVK_ANSI_O)
            case .fullContextAnswer: UInt32(kVK_Return)
            case .screenshotToChat: UInt32(kVK_ANSI_S)
            }
        }
    }

    private var handlers: [Action: () -> Void] = [:]
    private var hotKeyRefs: [Action: EventHotKeyRef] = [:]
    private var failedActions: Set<Action> = []
    private var retryTimer: Timer?
    private var eventHandler: EventHandlerRef?

    func register(_ handlers: [Action: () -> Void]) {
        self.handlers = handlers

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let hotkeys = Unmanaged<GlobalHotkeys>.fromOpaque(userData).takeUnretainedValue()
                if let action = Action(rawValue: hotKeyID.id) {
                    DispatchQueue.main.async {
                        hotkeys.handlers[action]?()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )

        failedActions = Set(Action.allCases.filter { !register($0) })
        scheduleRetryIfNeeded()
    }

    /// A second copy can temporarily own the same Carbon hotkeys — notably
    /// while replacing a development build with the installed app. Carbon
    /// returns an error in that case, and the old implementation discarded it
    /// forever. Retrying lets the surviving app claim the shortcuts as soon as
    /// the competing process exits.
    private func register(_ action: Action) -> Bool {
        guard hotKeyRefs[action] == nil else { return true }

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x4A52_4B54), // "JRKT"
            id: action.rawValue
        )
        let status = RegisterEventHotKey(
            action.keyCode,
            UInt32(controlKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, let hotKeyRef else { return false }
        hotKeyRefs[action] = hotKeyRef
        return true
    }

    private func scheduleRetryIfNeeded() {
        guard !failedActions.isEmpty, retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.failedActions = Set(self.failedActions.filter { !self.register($0) })
            guard self.failedActions.isEmpty else { return }
            timer.invalidate()
            self.retryTimer = nil
        }
    }

    func unregisterAll() {
        retryTimer?.invalidate()
        retryTimer = nil
        failedActions = []
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs = [:]
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit {
        unregisterAll()
    }
}
