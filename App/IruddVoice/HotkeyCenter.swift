import Carbon.HIToolbox
import IruddVoiceKit

/// Registers the global start/stop hotkey with Carbon's RegisterEventHotKey,
/// which needs no extra permission.
@MainActor
final class HotkeyCenter {
    var onPress: (() -> Void)?

    private var hotkeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { center.onPress?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// Replaces the current hotkey. Returns false if macOS refused it, for
    /// example because another app already uses it.
    @discardableResult
    func register(_ hotkey: Hotkey?) -> Bool {
        unregister()
        guard let hotkey else { return true }
        let id = EventHotKeyID(signature: OSType(0x4952_5644), id: 1) // "IRVD"
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotkeyRef)
        return status == noErr
    }

    func unregister() {
        if let hotkeyRef {
            UnregisterEventHotKey(hotkeyRef)
        }
        hotkeyRef = nil
    }
}
