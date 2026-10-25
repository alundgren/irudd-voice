import Carbon.HIToolbox
import IruddVoiceKit

/// Registers the global hotkeys with Carbon's RegisterEventHotKey, which
/// needs no extra permission.
@MainActor
final class HotkeyCenter {
    var onPress: ((HotkeyAction) -> Void)?

    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let action = HotkeyAction.allCases[Int(id.id)]
            MainActor.assumeIsolated { center.onPress?(action) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// Replaces the hotkey for `action`. Returns false if macOS refused it,
    /// for example because another app already uses it.
    @discardableResult
    func register(_ hotkey: Hotkey?, for action: HotkeyAction) -> Bool {
        unregister(action)
        guard let hotkey else { return true }
        let index = UInt32(HotkeyAction.allCases.firstIndex(of: action)!)
        let id = EventHotKeyID(signature: OSType(0x4952_5644), id: index) // "IRVD"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[action] = ref }
        return status == noErr
    }

    func unregister(_ action: HotkeyAction) {
        if let ref = refs.removeValue(forKey: action) {
            UnregisterEventHotKey(ref)
        }
    }
}
