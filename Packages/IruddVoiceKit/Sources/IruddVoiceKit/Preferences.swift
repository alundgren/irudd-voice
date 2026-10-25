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
}
