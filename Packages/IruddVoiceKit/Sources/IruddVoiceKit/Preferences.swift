import Foundation

/// How much of a thought is shown on screen while you talk.
public enum PreviewMode: String, CaseIterable, Sendable {
    /// Nothing on screen.
    case off
    /// A small dot while hearing you.
    case dot
    /// The live transcript, for testing.
    case transcript

    public var title: String {
        switch self {
        case .off: "Off"
        case .dot: "Dot"
        case .transcript: "Transcript"
        }
    }
}

/// Where preferences are kept. `UserDefaults` in the app, a dictionary in tests.
public protocol KeyValueStore: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStore {}

public final class MemoryStore: KeyValueStore {
    private var values: [String: Any] = [:]
    public init() {}
    public func object(forKey key: String) -> Any? { values[key] }
    public func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// Small user choices. Everything recorded (audio, text, labels) lives in the
/// SQLite database instead.
public final class Preferences {
    enum Key {
        static let isOn = "isOn"
        static let previewMode = "previewMode"
        static let hasCompletedSetup = "hasCompletedSetup"
        static let pinnedMicUID = "pinnedMicUID"
        static let pinnedMicName = "pinnedMicName"
        static let hotkey = "hotkey"
    }

    private let store: KeyValueStore

    public init(store: KeyValueStore) {
        self.store = store
    }

    /// The main switch. On by default once setup is done.
    public var isOn: Bool {
        get { store.object(forKey: Key.isOn) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.isOn) }
    }

    public var previewMode: PreviewMode {
        get { (store.object(forKey: Key.previewMode) as? String).flatMap(PreviewMode.init) ?? .off }
        set { store.set(newValue.rawValue, forKey: Key.previewMode) }
    }

    public var hasCompletedSetup: Bool {
        get { store.object(forKey: Key.hasCompletedSetup) as? Bool ?? false }
        set { store.set(newValue, forKey: Key.hasCompletedSetup) }
    }

    /// The exact device UID of the mic the app listens to. Only changed when
    /// the person picks a mic, never automatically.
    public var pinnedMicUID: String? {
        get { store.object(forKey: Key.pinnedMicUID) as? String }
        set { store.set(newValue, forKey: Key.pinnedMicUID) }
    }

    /// The pinned mic's name, to show while it's unplugged.
    public var pinnedMicName: String? {
        get { store.object(forKey: Key.pinnedMicName) as? String }
        set { store.set(newValue, forKey: Key.pinnedMicName) }
    }

    /// A hotkey for each action. None are set by default.
    public func hotkey(for action: HotkeyAction) -> Hotkey? {
        (store.object(forKey: action.preferenceKey) as? Data).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) }
    }

    public func setHotkey(_ hotkey: Hotkey?, for action: HotkeyAction) {
        store.set(hotkey.flatMap { try? JSONEncoder().encode($0) }, forKey: action.preferenceKey)
    }
}
