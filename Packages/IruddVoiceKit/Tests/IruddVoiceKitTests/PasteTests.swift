import Foundation
import Testing
@testable import IruddVoiceKit

final class FakeClipboard: Clipboard, @unchecked Sendable {
    private let lock = NSLock()
    private var _changeCount = 0
    var contents: [[String: Data]] = [["public.utf8-plain-text": Data("old".utf8)]]
    var snapshotResult: SnapshotResult?
    var writes: [String] = []
    var restores = 0

    var changeCount: Int { lock.withLock { _changeCount } }

    func snapshot() -> SnapshotResult {
        snapshotResult ?? .complete(ClipboardSnapshot(items: contents))
    }

    func writeDictation(_ text: String) -> Int {
        lock.withLock {
            writes.append(text)
            contents = [["public.utf8-plain-text": Data(text.utf8), "org.nspasteboard.ConcealedType": Data()]]
            _changeCount += 1
            return _changeCount
        }
    }

    func restore(_ snapshot: ClipboardSnapshot) {
        lock.withLock {
            contents = snapshot.items
            restores += 1
            _changeCount += 1
        }
    }

    func copy(_ text: String) {
        lock.withLock {
            contents = [["public.utf8-plain-text": Data(text.utf8)]]
            _changeCount += 1
        }
    }

    /// Someone else copies something while our text is on the clipboard.
    func userCopies(_ text: String) { copy(text) }
}

final class FakeKeyboard: Keyboard, @unchecked Sendable {
    private let lock = NSLock()
    var heldUntil: ContinuousClock.Instant?
    /// Keys held until the test lets go; `heldChecks` counts the polls.
    var holding = false
    private var _heldChecks = 0
    var heldChecks: Int { lock.withLock { _heldChecks } }
    var keyCode: UInt16 = 9
    var posted: [UInt16] = []
    var accessibility = true
    var onPost: (() -> Void)?

    func modifiersHeld() -> Bool {
        lock.withLock {
            _heldChecks += 1
            return holding || (heldUntil.map { ContinuousClock.now < $0 } ?? false)
        }
    }
    func pasteKeyCode() -> UInt16 { keyCode }
    func postCommand(keyCode: UInt16) {
        lock.withLock { posted.append(keyCode) }
        onPost?()
    }
    func canPost() -> Bool { accessibility }
}

final class FakeFocus: FocusReader, @unchecked Sendable {
    private let lock = NSLock()
    private var targets: [PasteTarget?]
    init(_ targets: PasteTarget?...) { self.targets = targets }
    /// Returns the queued targets in order, then keeps returning the last.
    func current() -> PasteTarget? {
        lock.withLock { targets.count > 1 ? targets.removeFirst() : targets.first ?? nil }
    }
}

let editorBox = PasteTarget(pid: 42, bundleID: "com.example.editor", appName: "Editor",
                            element: ElementID("box-1" as NSString, description: "text box 1"))
let otherBox = PasteTarget(pid: 42, bundleID: "com.example.editor", appName: "Editor",
                           element: ElementID("box-2" as NSString, description: "text box 2"))
let otherApp = PasteTarget(pid: 7, bundleID: "com.example.other", appName: "Other",
                           element: ElementID("box-1" as NSString, description: "text box 1"))

struct PasteTests {
    func settings() -> PasteSettings {
        var s = PasteSettings()
        s.restoreDelay = .milliseconds(50)
        s.modifierWait = .milliseconds(300)
        s.modifierPoll = .milliseconds(5)
        return s
    }

    @Test func pastesWithCommandVAndPutsTheClipboardBack() async {
        let clipboard = FakeClipboard()
        let keyboard = FakeKeyboard()
        let paster = Paster(clipboard: clipboard, keyboard: keyboard, focus: FakeFocus(editorBox), settings: settings())
        let outcome = await paster.paste("change the timeout", into: editorBox)
        #expect(outcome == .pasted)
        #expect(clipboard.writes == ["change the timeout"])
        #expect(keyboard.posted == [9])
        #expect(clipboard.contents == [["public.utf8-plain-text": Data("old".utf8)]])
    }

    @Test func neverPostsReturn() async {
        let keyboard = FakeKeyboard()
        let paster = Paster(clipboard: FakeClipboard(), keyboard: keyboard, focus: FakeFocus(editorBox), settings: settings())
        _ = await paster.paste("run the tests\n", into: editorBox)
        _ = await paster.paste("and deploy", into: editorBox)
        // Only ever V (9). Return is 36, keypad Enter 76.
        #expect(keyboard.posted == [9, 9])
        #expect(!keyboard.posted.contains(36) && !keyboard.posted.contains(76))
    }

    @Test func usesTheLayoutsVKey() async {
        let keyboard = FakeKeyboard()
        keyboard.keyCode = 47 // where "v" is on Dvorak
        let paster = Paster(clipboard: FakeClipboard(), keyboard: keyboard, focus: FakeFocus(editorBox), settings: settings())
        _ = await paster.paste("hello", into: editorBox)
        #expect(keyboard.posted == [47])
    }

    @Test func waitsForHeldKeysToBeLetGo() async {
        let keyboard = FakeKeyboard()
        keyboard.heldUntil = .now + .milliseconds(100)
        let paster = Paster(clipboard: FakeClipboard(), keyboard: keyboard, focus: FakeFocus(editorBox), settings: settings())
        let started = ContinuousClock.now
        #expect(await paster.paste("hello", into: editorBox) == .pasted)
        #expect(ContinuousClock.now - started >= .milliseconds(100))
    }

    /// Throw Away during the wait for held keys: nothing is written to the
    /// clipboard and nothing is pasted.
    @Test func stopDuringTheKeyWaitPastesNothing() async {
        let clipboard = FakeClipboard()
        let keyboard = FakeKeyboard()
        keyboard.holding = true
        var slow = settings()
        slow.modifierWait = .seconds(30)
        let paster = Paster(clipboard: clipboard, keyboard: keyboard, focus: FakeFocus(editorBox), settings: slow)
        let stop = StopFlag()
        let paste = Task { await paster.paste("hello", into: editorBox, shouldStop: { stage in stop.ask(stage) }) }
        await waitUntil { keyboard.heldChecks > 0 }
        stop.set()
        keyboard.holding = false
        #expect(await paste.value == .stopped)
        #expect(stop.stages == [.afterKeyWait])
        #expect(clipboard.writes.isEmpty && clipboard.restores == 0)
        #expect(keyboard.posted.isEmpty)
    }

    /// Throw Away at the last moment: our text was on the clipboard, so the
    /// old contents are put back, and ⌘V never happens.
    @Test func stopRightBeforeTheKeystrokeRestoresTheClipboard() async {
        let clipboard = FakeClipboard()
        let keyboard = FakeKeyboard()
        let paster = Paster(clipboard: clipboard, keyboard: keyboard, focus: FakeFocus(editorBox), settings: settings())
        let outcome = await paster.paste("hello", into: editorBox, shouldStop: { $0 == .beforeKeystroke })
        #expect(outcome == .stopped)
        #expect(clipboard.writes == ["hello"] && clipboard.restores == 1)
        #expect(clipboard.contents == [["public.utf8-plain-text": Data("old".utf8)]])
        #expect(keyboard.posted.isEmpty)
    }

    @Test func asksAtBothStagesWhenNotStopped() async {
        let stop = StopFlag()
        let keyboard = FakeKeyboard()
        let paster = Paster(clipboard: FakeClipboard(), keyboard: keyboard, focus: FakeFocus(editorBox), settings: settings())
        #expect(await paster.paste("hello", into: editorBox, shouldStop: { stop.ask($0) }) == .pasted)
        #expect(stop.stages == [.afterKeyWait, .beforeKeystroke])
        #expect(keyboard.posted == [9])
    }

    @Test func givesUpIfKeysStayHeld() async {
        let keyboard = FakeKeyboard()
        keyboard.heldUntil = .now + .seconds(60)
        let clipboard = FakeClipboard()
        let paster = Paster(clipboard: clipboard, keyboard: keyboard, focus: FakeFocus(editorBox), settings: settings())
        #expect(await paster.paste("hello", into: editorBox) == .waiting(.keysHeld))
        #expect(keyboard.posted.isEmpty)
        #expect(clipboard.writes.isEmpty)
    }

    @Test func movedToAnotherBoxOrAppPastesNothing() async {
        for moved in [otherBox, otherApp] {
            let keyboard = FakeKeyboard()
            let clipboard = FakeClipboard()
            let paster = Paster(clipboard: clipboard, keyboard: keyboard, focus: FakeFocus(moved), settings: settings())
            #expect(await paster.paste("hello", into: editorBox) == .waiting(.targetMoved))
            #expect(keyboard.posted.isEmpty)
            #expect(clipboard.writes.isEmpty)
        }
    }

    @Test func movingAtTheLastMomentPastesNothingAndRestores() async {
        let keyboard = FakeKeyboard()
        let clipboard = FakeClipboard()
        // Focus is right at the first check, gone at the second.
        let paster = Paster(clipboard: clipboard, keyboard: keyboard, focus: FakeFocus(editorBox, otherApp),
                            settings: settings())
        #expect(await paster.paste("hello", into: editorBox) == .waiting(.targetMoved))
        #expect(keyboard.posted.isEmpty)
        #expect(clipboard.contents == [["public.utf8-plain-text": Data("old".utf8)]])
    }

    @Test func unknownFocusNeverMatches() async {
        let unknown = PasteTarget(pid: 42, bundleID: nil, appName: nil, element: nil)
        let paster = Paster(clipboard: FakeClipboard(), keyboard: FakeKeyboard(), focus: FakeFocus(unknown), settings: settings())
        #expect(await paster.paste("hello", into: unknown) == .waiting(.targetMoved))
    }

    @Test func deniedOrIncompleteClipboardPastesNothing() async {
        for (result, reason) in [(SnapshotResult.denied, WaitReason.clipboardDenied),
                                 (.incomplete("public.tiff"), .clipboardIncomplete)] {
            let clipboard = FakeClipboard()
            clipboard.snapshotResult = result
            let keyboard = FakeKeyboard()
            let paster = Paster(clipboard: clipboard, keyboard: keyboard, focus: FakeFocus(editorBox), settings: settings())
            #expect(await paster.paste("hello", into: editorBox) == .waiting(reason))
            #expect(keyboard.posted.isEmpty)
            #expect(clipboard.writes.isEmpty)
        }
    }

    @Test func doesNotRestoreOverSomethingNewlyCopied() async {
        let clipboard = FakeClipboard()
        let keyboard = FakeKeyboard()
        keyboard.onPost = { clipboard.userCopies("new thing") }
        let paster = Paster(clipboard: clipboard, keyboard: keyboard, focus: FakeFocus(editorBox), settings: settings())
        #expect(await paster.paste("hello", into: editorBox) == .pasted)
        #expect(clipboard.restores == 0)
        #expect(clipboard.contents == [["public.utf8-plain-text": Data("new thing".utf8)]])
    }

    @Test func noAccessibilityPastesNothing() async {
        let keyboard = FakeKeyboard()
        keyboard.accessibility = false
        let clipboard = FakeClipboard()
        let paster = Paster(clipboard: clipboard, keyboard: keyboard, focus: FakeFocus(editorBox), settings: settings())
        #expect(await paster.paste("hello", into: editorBox) == .waiting(.noAccessibility))
        #expect(clipboard.writes.isEmpty)
    }

    @Test func backToBackPastesDontOverlap() async {
        let clipboard = FakeClipboard()
        let keyboard = FakeKeyboard()
        let paster = Paster(clipboard: clipboard, keyboard: keyboard, focus: FakeFocus(editorBox), settings: settings())
        async let first = paster.paste("first", into: editorBox)
        async let second = paster.paste("second", into: editorBox)
        let outcomes = await [first, second]
        #expect(outcomes == [.pasted, .pasted])
        // Each paste restored the clipboard before the next one wrote, so the
        // snapshot the second one took was the original, not "first".
        #expect(clipboard.restores == 2)
        #expect(clipboard.contents == [["public.utf8-plain-text": Data("old".utf8)]])
    }
}

/// A Throw Away mark for paste tests: records the stages it's asked at.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var asked: [PasteStage] = []
    func set() { lock.withLock { stopped = true } }
    var stages: [PasteStage] { lock.withLock { asked } }
    func ask(_ stage: PasteStage) -> Bool {
        lock.withLock {
            asked.append(stage)
            return stopped
        }
    }
}
