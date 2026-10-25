import Foundation

/// Where the text should go: the app and the text box that had focus when
/// the thought ended. Pasting only happens if both are still the same.
public struct PasteTarget: Equatable, Sendable {
    public let pid: Int32
    public let bundleID: String?
    public let appName: String?
    /// Identifies the focused element (or, if the app exposes none, its
    /// focused window). Compared with `==`; nil means unknown.
    public let element: ElementID?

    public init(pid: Int32, bundleID: String?, appName: String?, element: ElementID?) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.element = element
    }

    /// Same app and same text box. An unknown element never matches, so a
    /// paste is never guessed into place.
    public func isSame(as other: PasteTarget) -> Bool {
        pid == other.pid && element != nil && element == other.element
    }
}

/// An accessibility element, wrapped so it can be compared and sent across
/// threads. `isEqual` uses CFEqual on the real AXUIElement.
public struct ElementID: Equatable, @unchecked Sendable {
    let object: AnyObject
    let describe: String

    public init(_ object: AnyObject, description: String) {
        self.object = object
        describe = description
    }

    public static func == (a: ElementID, b: ElementID) -> Bool {
        CFEqual(a.object, b.object)
    }
}

/// A copy of everything on the clipboard, so it can be put back.
public struct ClipboardSnapshot: Sendable, Equatable {
    /// One entry per pasteboard item: type identifier → data.
    public let items: [[String: Data]]
    public init(items: [[String: Data]]) { self.items = items }
}

public enum SnapshotResult: Sendable, Equatable {
    case complete(ClipboardSnapshot)
    /// macOS wouldn't let the app read the clipboard.
    case denied
    /// Some of the clipboard couldn't be read, so it couldn't be put back whole.
    case incomplete(String)
}

/// The system clipboard. Faked in tests: tests never touch the real one.
public protocol Clipboard: Sendable {
    var changeCount: Int { get }
    func snapshot() -> SnapshotResult
    /// Writes `text` marked as concealed and transient, so clipboard
    /// managers skip it. Returns the new change count.
    func writeDictation(_ text: String) -> Int
    func restore(_ snapshot: ClipboardSnapshot)
    /// Puts `text` on the clipboard to keep (the Copy button).
    func copy(_ text: String)
}

/// Keyboard access: held modifiers and posting ⌘V. Faked in tests.
public protocol Keyboard: Sendable {
    /// True while ⌘, ⌥, ⌃, ⇧ or fn is held down.
    func modifiersHeld() -> Bool
    /// The key code that types "v" with ⌘ held on the current layout
    /// (9 on QWERTY, different on Dvorak).
    func pasteKeyCode() -> UInt16
    /// Posts ⌘ + `keyCode` down and up. Never anything else.
    func postCommand(keyCode: UInt16)
    /// Accessibility permission, needed to post keys.
    func canPost() -> Bool
}

/// Reads what currently has keyboard focus. Faked in tests.
public protocol FocusReader: Sendable {
    func current() -> PasteTarget?
}

public enum PasteOutcome: Equatable, Sendable {
    case pasted
    /// Not pasted; the text waits for Paste here or Copy.
    case waiting(WaitReason)
    /// Throw Away came before ⌘V: nothing was pasted, and the clipboard is
    /// as it was.
    case stopped
}

/// Where a paste asks whether to stop. `check`: after waiting for held keys,
/// and before giving up with `.waiting`, so a thrown-away thought is never
/// left as waiting text. `beforeKeystroke`: the last time, right before the
/// final focus check and ⌘V; after it says go, the paste can't be stopped.
public enum PasteStage: Sendable {
    case check
    case beforeKeystroke
}

public enum WaitReason: String, Equatable, Sendable {
    case targetMoved
    case keysHeld
    case clipboardDenied
    case clipboardIncomplete
    case noAccessibility

    public var description: String {
        switch self {
        case .targetMoved: "You moved to another app or text box, so nothing was pasted."
        case .keysHeld: "Keys were held down for too long, so nothing was pasted."
        case .clipboardDenied, .clipboardIncomplete: "Not pasted: the app can't read the clipboard to put it back afterwards."
        case .noAccessibility: "Not pasted: pasting needs Accessibility permission."
        }
    }
}

public struct PasteSettings: Sendable {
    /// How long to wait for held keys (e.g. ⌘ from a shortcut) to be let go.
    public var modifierWait: Duration = .seconds(2)
    public var modifierPoll: Duration = .milliseconds(20)
    /// How long the pasted text stays on the clipboard before the old
    /// contents come back, so slow apps have read it.
    public var restoreDelay: Duration = .milliseconds(1000)
    public init() {}
}

/// Pastes text into the target, one paste at a time, and puts the old
/// clipboard back afterwards. Never presses Return.
public actor Paster {
    private let clipboard: Clipboard
    private let keyboard: Keyboard
    private let focus: FocusReader
    private let settings: PasteSettings
    private var queue: Task<Void, Never>?

    public init(clipboard: Clipboard, keyboard: Keyboard, focus: FocusReader, settings: PasteSettings = PasteSettings()) {
        self.clipboard = clipboard
        self.keyboard = keyboard
        self.focus = focus
        self.settings = settings
    }

    /// Pastes after any paste already in progress has finished.
    /// `shouldStop` is asked at each `PasteStage`; true stops the paste
    /// (Throw Away), with nothing pasted and the clipboard put back.
    public func paste(_ text: String, into target: PasteTarget,
                      shouldStop: @escaping @Sendable (PasteStage) async -> Bool = { _ in false }) async -> PasteOutcome {
        let previous = queue
        let job = Task { [self] () -> PasteOutcome in
            await previous?.value
            return await pasteNow(text, into: target, shouldStop: shouldStop)
        }
        queue = Task { _ = await job.value }
        return await job.value
    }

    /// Pastes into whatever has focus now (Paste here, Paste last again).
    public func pasteHere(_ text: String) async -> PasteOutcome {
        guard let target = focus.current() else { return .waiting(.targetMoved) }
        return await paste(text, into: target)
    }

    /// The text as one line: each run of line breaks, with the spaces and
    /// tabs around it, becomes one space. A pasted line break would press
    /// Return in a chat box and send the message.
    public static func oneLine(_ text: String) -> String {
        text.replacing(/[ \t]*[\r\n\u{0B}\u{0C}\u{85}\u{2028}\u{2029}]+[ \t]*/.matchingSemantics(.unicodeScalar),
                       with: " ")
    }

    private func pasteNow(_ text: String, into target: PasteTarget,
                          shouldStop: @Sendable (PasteStage) async -> Bool) async -> PasteOutcome {
        /// Not pasting: stopped if Throw Away marked it, otherwise waiting.
        func notPasted(_ reason: WaitReason) async -> PasteOutcome {
            await shouldStop(.check) ? .stopped : .waiting(reason)
        }
        guard keyboard.canPost() else { return await notPasted(.noAccessibility) }

        // A shortcut's ⌘ still held would turn ⌘V into something else.
        let clock = ContinuousClock()
        let deadline = clock.now + settings.modifierWait
        while keyboard.modifiersHeld() {
            if clock.now >= deadline { return await notPasted(.keysHeld) }
            try? await Task.sleep(for: settings.modifierPoll)
        }
        if await shouldStop(.check) { return .stopped }

        guard let now = focus.current(), now.isSame(as: target) else { return await notPasted(.targetMoved) }

        let saved: ClipboardSnapshot
        switch clipboard.snapshot() {
        case .complete(let snapshot): saved = snapshot
        case .denied: return await notPasted(.clipboardDenied)
        case .incomplete: return await notPasted(.clipboardIncomplete)
        }

        // Every paste goes through here, so this is the one place line breaks go.
        let ours = clipboard.writeDictation(Self.oneLine(text))

        // The last chance to stop. After this the thought is committed: a
        // failed focus check below makes it waiting text, which Throw Away
        // can still drop.
        if await shouldStop(.beforeKeystroke) {
            if clipboard.changeCount == ours { clipboard.restore(saved) }
            return .stopped
        }
        // Last focus check, with nothing awaited between it and ⌘V.
        guard let still = focus.current(), still.isSame(as: target) else {
            if clipboard.changeCount == ours { clipboard.restore(saved) }
            return .waiting(.targetMoved)
        }
        keyboard.postCommand(keyCode: keyboard.pasteKeyCode())

        try? await Task.sleep(for: settings.restoreDelay)
        // Only put the old clipboard back if nobody copied something new meanwhile.
        if clipboard.changeCount == ours {
            clipboard.restore(saved)
        }
        return .pasted
    }
}
