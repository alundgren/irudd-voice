import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// NSPasteboard.general. Only the app uses this; tests use a fake.
public final class SystemClipboard: Clipboard, @unchecked Sendable {
    private let pasteboard = NSPasteboard.general
    // Markers clipboard managers (Raycast, Maccy, …) respect: don't record this.
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    public init() {}

    public var changeCount: Int { pasteboard.changeCount }

    public func snapshot() -> SnapshotResult {
        // Reading without "Always allow" would make macOS show its clipboard
        // alert mid-paste, so treat that as denied.
        guard pasteboard.accessBehavior == .alwaysAllow else { return .denied }
        var items: [[String: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var entry: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return .incomplete(type.rawValue) }
                entry[type.rawValue] = data
            }
            items.append(entry)
        }
        return .complete(ClipboardSnapshot(items: items))
    }

    public func writeDictation(_ text: String) -> Int {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.concealed)
        item.setData(Data(), forType: Self.transient)
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    public func restore(_ snapshot: ClipboardSnapshot) {
        pasteboard.clearContents()
        let items = snapshot.items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    public func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// Real keyboard: modifier state, layout lookup and ⌘V via CGEvent.
public final class SystemKeyboard: Keyboard, @unchecked Sendable {
    public init() {}

    public func modifiersHeld() -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return !flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]).isEmpty
    }

    public func pasteKeyCode() -> UInt16 {
        // The text input APIs must run on the main thread.
        if Thread.isMainThread { return Self.findVKey() }
        return DispatchQueue.main.sync { Self.findVKey() }
    }

    public func postCommand(keyCode: UInt16) {
        // A private event source, so keys the person happens to hold don't
        // leak into the event.
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }

    public func canPost() -> Bool {
        AXIsProcessTrusted()
    }

    /// Finds the key that types "v" with ⌘ held. Layouts like "Dvorak – QWERTY ⌘"
    /// switch to QWERTY while ⌘ is down, so ⌘ is part of the lookup.
    static func findVKey() -> UInt16 {
        let fallback = UInt16(kVK_ANSI_V)
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> UInt16 in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return fallback }
            let commandState = UInt32((cmdKey >> 8) & 0xFF)
            for code in UInt16(0)..<128 {
                var deadKeys: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), commandState,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeys, chars.count, &length, &chars)
                if status == noErr, length == 1, chars[0] == UniChar(("v" as Unicode.Scalar).value) {
                    return code
                }
            }
            return fallback
        }
    }
}

/// Reads the focused app and text box through the accessibility API.
public final class AccessibilityFocus: FocusReader, @unchecked Sendable {
    private let lock = NSLock()
    private var enabledManualAccessibility: Set<pid_t> = []

    public init() {}

    public func current() -> PasteTarget? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var pid: pid_t = 0
        if let app: AXUIElement = copy(system, kAXFocusedApplicationAttribute) {
            AXUIElementGetPid(app, &pid)
        } else if let front = NSWorkspace.shared.frontmostApplication {
            pid = front.processIdentifier
        }
        guard pid != 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)

        var element: AXUIElement? = copy(app, kAXFocusedUIElementAttribute)
        if element == nil, enableManualAccessibility(app, pid: pid) {
            // Chromium and Electron apps (Chrome, T3 Code, VS Code) only build
            // their accessibility tree when asked.
            element = copy(app, kAXFocusedUIElementAttribute)
        }
        var label = "focused element"
        if element == nil {
            element = copy(app, kAXFocusedWindowAttribute)
            label = "focused window"
        }
        let running = NSRunningApplication(processIdentifier: pid)
        return PasteTarget(pid: pid, bundleID: running?.bundleIdentifier, appName: running?.localizedName,
                           element: element.map { ElementID($0, description: label) })
    }

    private func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// Returns true if it was turned on just now (so a retry can help).
    private func enableManualAccessibility(_ app: AXUIElement, pid: pid_t) -> Bool {
        let fresh = lock.withLock { enabledManualAccessibility.insert(pid).inserted }
        guard fresh else { return false }
        return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }
}
