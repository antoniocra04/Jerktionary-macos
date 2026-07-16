import Carbon.HIToolbox
import Foundation

/// Carbon-based global hotkeys (work while other apps are focused, no
/// Accessibility permission needed):
///   Ctrl+Shift+Space — answer now
///   Ctrl+Shift+O     — toggle overlay
///   Ctrl+Shift+Enter — full-context answer
final class GlobalHotkeys {
    enum Action: UInt32, CaseIterable {
        case answerNow = 1
        case toggleOverlay = 2
        case fullContextAnswer = 3

        var keyCode: UInt32 {
            switch self {
            case .answerNow: UInt32(kVK_Space)
            case .toggleOverlay: UInt32(kVK_ANSI_O)
            case .fullContextAnswer: UInt32(kVK_Return)
            }
        }
    }

    private var handlers: [Action: () -> Void] = [:]
    private var hotKeyRefs: [EventHotKeyRef?] = []
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

        let modifiers = UInt32(controlKey | shiftKey)
        for action in Action.allCases {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x4A52_4B54), id: action.rawValue) // "JRKT"
            RegisterEventHotKey(
                action.keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            hotKeyRefs.append(hotKeyRef)
        }
    }

    func unregisterAll() {
        for ref in hotKeyRefs {
            if let ref {
                UnregisterEventHotKey(ref)
            }
        }
        hotKeyRefs = []
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit {
        unregisterAll()
    }
}
