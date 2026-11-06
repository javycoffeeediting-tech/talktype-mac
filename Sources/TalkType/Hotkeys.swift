import Carbon
import Foundation

enum HotkeyAction: UInt32, CaseIterable {
    case dictate = 1
    case translate
    case condense
    case cancel
}

/// Global shortcuts through Carbon, which needs no extra permission and reports the release too.
final class HotkeyCenter {
    private static let signature = OSType(0x54414C4B)

    var pressed: ((HotkeyAction) -> Void)?
    var released: ((TimeInterval) -> Void)?

    private var combos: [HotkeyAction: KeyCombo] = [:]
    private var registered: [HotkeyAction: EventHotKeyRef] = [:]
    private var pressedAt: Date?

    init() {
        var kinds = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let center = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else {
                return noErr
            }

            var id = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &id
            )

            if status == noErr, let action = HotkeyAction(rawValue: id.id) {
                let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue().handle(action, isPress: isPress)
            }

            return noErr
        }, kinds.count, &kinds, center, nil)
    }

    /// Switches a shortcut, keeping the old one if the new one is taken. Nil removes it.
    @discardableResult
    func set(_ action: HotkeyAction, to combo: KeyCombo?) -> Bool {
        let previous = combos[action]
        unregister(action)
        combos[action] = nil

        guard let combo else {
            return true
        }

        if register(action, combo) {
            combos[action] = combo
            return true
        }

        if let previous, register(action, previous) {
            combos[action] = previous
        }

        return false
    }

    /// Lets the shortcuts through while one is being retyped in Settings.
    func suspend() {
        HotkeyAction.allCases.forEach(unregister)
    }

    func resume() {
        for (action, combo) in combos where registered[action] == nil {
            _ = register(action, combo)
        }
    }

    private func handle(_ action: HotkeyAction, isPress: Bool) {
        if isPress {
            pressedAt = Date()
            pressed?(action)
        } else if action != .cancel, let pressedAt {
            released?(Date().timeIntervalSince(pressedAt))
        }
    }

    private func register(_ action: HotkeyAction, _ combo: KeyCombo) -> Bool {
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: HotkeyCenter.signature, id: action.rawValue)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetEventDispatcherTarget(), 0, &reference)
        guard status == noErr, let reference else {
            return false
        }

        registered[action] = reference
        return true
    }

    private func unregister(_ action: HotkeyAction) {
        if let reference = registered.removeValue(forKey: action) {
            UnregisterEventHotKey(reference)
        }
    }
}
