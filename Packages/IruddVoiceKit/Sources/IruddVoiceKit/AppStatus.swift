/// What the app is doing right now, as shown by the menu-bar icon and the
/// top of the panel.
public enum AppStatus: String, CaseIterable, Sendable {
    /// First-run setup isn't finished, so the app can't listen yet.
    case notSetUp
    /// The switch is off. The mic stream is closed.
    case off
    /// On, listening to the pinned mic, waiting for you to unmute.
    case ready
    /// Recording a thought.
    case hearing
    /// The thought is being turned into clean text.
    case cleaningUp
    /// Clean text is ready but couldn't be pasted (you moved to another app).
    case textWaiting
    /// The pinned mic isn't connected. The app waits; it never switches mics.
    case micMissing

    /// Picks the status to show. Unfinished setup wins over everything, then
    /// being off, then a missing mic, then the current activity.
    public static func resolve(isSetUp: Bool, isOn: Bool, micConnected: Bool, activity: Activity) -> AppStatus {
        guard isSetUp else { return .notSetUp }
        guard isOn else { return .off }
        guard micConnected else { return .micMissing }
        switch activity {
        case .idle: return .ready
        case .hearing: return .hearing
        case .cleaningUp: return .cleaningUp
        case .textWaiting: return .textWaiting
        }
    }

    public enum Activity: Sendable {
        case idle, hearing, cleaningUp, textWaiting
    }

    public var title: String {
        switch self {
        case .notSetUp: "Not set up"
        case .off: "Off"
        case .ready: "Ready"
        case .hearing: "Hearing you"
        case .cleaningUp: "Cleaning up"
        case .textWaiting: "Text waiting"
        case .micMissing: "Mic missing"
        }
    }

    public var detail: String {
        switch self {
        case .notSetUp: "Allow a few permissions and pick a mic to start."
        case .off: "Not listening. The mic is closed."
        case .ready: "Unmute the mic to start a thought."
        case .hearing: "Mute the mic when you're done."
        case .cleaningUp: "Turning your words into clean text."
        case .textWaiting: "Put your cursor where it goes, then press Paste Here below."
        case .micMissing: "Plug the mic back in. The app won't use another mic."
        }
    }

    /// SF Symbol for the menu bar.
    public var symbolName: String {
        switch self {
        case .notSetUp: "mic.badge.plus"
        case .off: "mic.slash"
        case .ready: "mic"
        case .hearing: "mic.fill"
        case .cleaningUp: "sparkles"
        case .textWaiting: "text.badge.plus"
        case .micMissing: "mic.badge.xmark"
        }
    }
}
