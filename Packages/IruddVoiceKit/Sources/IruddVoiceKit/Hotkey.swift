/// What a hotkey does.
public enum HotkeyAction: String, CaseIterable, Sendable {
    case startStop
    case pasteLast
    case throwAway

    public var title: String {
        switch self {
        case .startStop: "Start/stop thought"
        case .pasteLast: "Paste last again"
        case .throwAway: "Throw away current"
        }
    }

    public var help: String {
        switch self {
        case .startStop:
            "Starts a thought, or ends the one in progress. For mics without a mute button, like AirPods. A thought started this way also ends after 5 seconds of silence."
        case .pasteLast:
            "Pastes the waiting text, or the last text again, where your cursor is now. Text you threw away is never pasted again."
        case .throwAway:
            "Acts on what the menu-bar icon shows: ends the thought you're saying, drops the newest thought still being cleaned (up to the moment it's pasted), or drops waiting text. Nothing is pasted, and the audio is still saved."
        }
    }

    var preferenceKey: String {
        self == .startStop ? "hotkey" : "hotkey.\(rawValue)"
    }
}

/// A global keyboard shortcut. Stored as the Carbon key code and modifier
/// mask that `RegisterEventHotKey` takes, plus text to show.
public struct Hotkey: Sendable, Equatable, Codable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    public let display: String

    public init(keyCode: UInt32, carbonModifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.display = display
    }

    // Carbon modifier bits (cmdKey, shiftKey, optionKey, controlKey).
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    /// Function keys F1–F20 work alone; anything else needs ⌘, ⌥ or ⌃ so
    /// typing never triggers it.
    public static func isAllowed(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        let functionKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                         105, 107, 113, 106, 64, 79, 80, 90]
        if functionKeys.contains(keyCode) { return true }
        return carbonModifiers & (command | option | control) != 0
    }

    /// Names for keys whose character isn't useful to show.
    public static func keyName(keyCode: UInt32) -> String? {
        let names: [UInt32: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
            106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 117: "Forward Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        ]
        return names[keyCode]
    }

    public static func modifierSymbols(_ carbonModifiers: UInt32) -> String {
        var text = ""
        if carbonModifiers & control != 0 { text += "⌃" }
        if carbonModifiers & option != 0 { text += "⌥" }
        if carbonModifiers & shift != 0 { text += "⇧" }
        if carbonModifiers & command != 0 { text += "⌘" }
        return text
    }
}
