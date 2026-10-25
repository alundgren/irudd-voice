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
    private var _calls = 0
    init(_ targets: PasteTarget?...) { self.targets = targets }
    /// How many times focus was read.
    var calls: Int { lock.withLock { _calls } }
    /// Returns the queued targets in order, then keeps returning the last.
    func current() -> PasteTarget? {
        lock.withLock {
            _calls += 1
            return targets.count > 1 ? targets.removeFirst() : targets.first ?? nil
        }
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

    /// A line break in the clipboard text would press Return in a chat box:
    /// every kind becomes one space, whatever path the paste came from.
    @Test func pastedTextIsAlwaysOneLine() async {
        let clipboard = FakeClipboard()
        let paster = Paster(clipboard: clipboard, keyboard: FakeKeyboard(), focus: FakeFocus(editorBox),
                            settings: settings())
        _ = await paster.paste("Run the tests.\r\nThen deploy.\n\n Done", into: editorBox)
        _ = await paster.pasteHere("one\rtwo\u{2028}three \u{2029}\tfour\u{85}five")
        #expect(clipboard.writes == ["Run the tests. Then deploy. Done", "one two three four five"])
        #expect(Paster.oneLine("no breaks,  two spaces") == "no breaks,  two spaces")
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
        #expect(stop.stages == [.check])
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

    /// Marked, and the keys stay held past the deadline: thrown away, not
    /// left as waiting text.
    @Test func markedWithKeysHeldPastTheDeadlineIsStopped() async {
        let clipboard = FakeClipboard()
        let keyboard = FakeKeyboard()
        keyboard.holding = true
        let paster = Paster(clipboard: clipboard, keyboard: keyboard, focus: FakeFocus(editorBox), settings: settings())
        let stop = StopFlag()
        let paste = Task { await paster.paste("hello", into: editorBox, shouldStop: { stop.ask($0) }) }
        await waitUntil { keyboard.heldChecks > 0 }
        stop.set()
        #expect(await paste.value == .stopped)
        #expect(stop.stages == [.check])
        #expect(clipboard.writes.isEmpty && keyboard.posted.isEmpty)
        // Unmarked, the same paste waits.
        let unmarked = await paster.paste("hello", into: editorBox, shouldStop: { _ in false })
        #expect(unmarked == .waiting(.keysHeld))
    }

    /// Every way of giving up asks first, so a marked thought is stopped.
    @Test func markedThoughtIsNeverLeftWaiting() async {
        let denied = FakeClipboard()
        denied.snapshotResult = .denied
        let noAccess = FakeKeyboard()
        noAccess.accessibility = false
        let cases: [(Clipboard, Keyboard, FocusReader)] = [
            (FakeClipboard(), FakeKeyboard(), FakeFocus(otherBox)),
            (denied, FakeKeyboard(), FakeFocus(editorBox)),
            (FakeClipboard(), noAccess, FakeFocus(editorBox)),
        ]
        for (clipboard, keyboard, focus) in cases {
            let paster = Paster(clipboard: clipboard, keyboard: keyboard, focus: focus, settings: settings())
            #expect(await paster.paste("hello", into: editorBox, shouldStop: { $0 == .check }) == .stopped)
        }
    }

    /// The last stop question comes before the last focus check, so nothing
    /// is awaited between that check and ⌘V. A committed thought that then
    /// fails the focus check becomes waiting text.
    @Test func lastFocusCheckIsRightBeforeTheKeystroke() async {
        let clipboard = FakeClipboard()
        let keyboard = FakeKeyboard()
        let focus = FakeFocus(editorBox, otherBox)
        let paster = Paster(clipboard: clipboard, keyboard: keyboard, focus: focus, settings: settings())
        let focusReads = Counter()
        let outcome = await paster.paste("hello", into: editorBox, shouldStop: { stage in
            if stage == .beforeKeystroke { focusReads.set(focus.calls) }
            return false
        })
        // Asked after the first focus check and before the last one.
        #expect(focusReads.value == 1)
        #expect(focus.calls == 2)
        #expect(outcome == .waiting(.targetMoved))
        #expect(clipboard.restores == 1 && keyboard.posted.isEmpty)
    }

    @Test func asksAtBothStagesWhenNotStopped() async {
        let stop = StopFlag()
        let keyboard = FakeKeyboard()
        let paster = Paster(clipboard: FakeClipboard(), keyboard: keyboard, focus: FakeFocus(editorBox), settings: settings())
        #expect(await paster.paste("hello", into: editorBox, shouldStop: { stop.ask($0) }) == .pasted)
        #expect(stop.stages == [.check, .beforeKeystroke])
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

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var number = 0
    func set(_ value: Int) { lock.withLock { number = value } }
    var value: Int { lock.withLock { number } }
}

struct PasteAgainTests {
    func row(_ id: Int64, status: String = "transcribed", raw: String? = "raw text", pasted: String? = nil,
             cleaned: String? = nil) -> ChunkSummary {
        ChunkSummary(id: id, status: status, error: nil, rawText: raw, pastedText: pasted, cleanedText: cleaned,
                     durationMs: 1000, endReason: "muteButton",
                     endedAt: Date(), audioFormat: "flac", audioSampleRate: 16_000, audioBytes: 100)
    }

    @Test func pastesTheDeliveredTextOfTheNewestThought() {
        var memory = PasteAgain()
        memory.started(id: 1)
        memory.delivered(id: 1, text: "Run the tests.", outcome: .pasted)
        #expect(memory.text(waiting: nil, newest: row(1))! == (1, "Run the tests."))
        // Waiting text comes first.
        #expect(memory.text(waiting: (2, "Waiting."), newest: row(1))! == (2, "Waiting."))
    }

    /// A row this run never saw (saved before the app restarted): its raw
    /// text, since nothing is in flight for it.
    @Test func rowFromBeforeThisRunPastesItsRawText() {
        #expect(PasteAgain().text(waiting: nil, newest: row(5))! == (5, "raw text"))
    }

    /// After a restart, a row that was pasted cleaned pastes the cleaned
    /// text again; one held as waiting (nothing pasted yet) its cleaned text.
    @Test func rowFromBeforeThisRunPastesWhatWasDelivered() {
        let pasted = row(5, pasted: "Run the tests.", cleaned: "Run the tests.")
        #expect(PasteAgain().text(waiting: nil, newest: pasted)! == (5, "Run the tests."))
        let waiting = row(6, cleaned: "Deploy it.")
        #expect(PasteAgain().text(waiting: nil, newest: waiting)! == (6, "Deploy it."))
    }

    /// B is transcribed (the newest row) but still being cleaned: Paste last
    /// again pastes nothing until B is delivered, never B's raw text early.
    @Test func thoughtInFlightIsNotPastedUntilDelivered() {
        var memory = PasteAgain()
        memory.started(id: 1)
        memory.delivered(id: 1, text: "First.", outcome: .pasted)
        memory.started(id: 2)
        #expect(memory.text(waiting: nil, newest: row(2)) == nil)
        // Not the older thought either.
        #expect(memory.lastDelivered! == (1, "First."))
        memory.delivered(id: 2, text: "Second, cleaned.", outcome: .pasted)
        #expect(memory.text(waiting: nil, newest: row(2))! == (2, "Second, cleaned."))
    }

    /// B in flight and marked by Throw Away: nothing before its delivery
    /// (PasteAgain isn't told about the mark), and nothing after it's
    /// discarded or its paste is stopped.
    @Test func markedThoughtInFlightIsNeverPasted() {
        for stoppedDuringPaste in [false, true] {
            var memory = PasteAgain()
            memory.started(id: 1)
            memory.delivered(id: 1, text: "First.", outcome: .pasted)
            memory.started(id: 2)
            #expect(memory.text(waiting: nil, newest: row(2)) == nil)
            if stoppedDuringPaste {
                memory.delivered(id: 2, text: "Second.", outcome: .stopped)
            } else {
                memory.thrownAway(id: 2)
            }
            #expect(memory.text(waiting: nil, newest: row(2)) == nil)
        }
    }

    /// Throw Away stopped the paste before ⌘V (or the paste gave up after
    /// the mark): nothing to paste again, even before the row's new status
    /// is read back, and the older thought isn't pasted instead.
    @Test func stoppedPasteIsNotPastedAgain() {
        var memory = PasteAgain()
        memory.delivered(id: 1, text: "First.", outcome: .pasted)
        memory.started(id: 2)
        memory.delivered(id: 2, text: "Second.", outcome: .stopped)
        #expect(memory.text(waiting: nil, newest: row(2)) == nil)
        #expect(memory.text(waiting: nil, newest: row(2, status: "discarded")) == nil)
    }

    /// The waiting row's Throw Away button, or the hotkey on Text waiting:
    /// both drop the waiting text the same way.
    @Test func droppedWaitingTextIsNotPastedAgain() {
        var memory = PasteAgain()
        memory.started(id: 3)
        memory.delivered(id: 3, text: "Held.", outcome: .waiting(.targetMoved))
        #expect(memory.text(waiting: (3, "Held."), newest: row(3))! == (3, "Held."))
        memory.thrownAway(id: 3)
        #expect(memory.lastDelivered == nil)
        #expect(memory.text(waiting: nil, newest: row(3)) == nil)
    }

    /// Thrown away before its paste started (during cleanup), or while it
    /// was being said: never delivered, never pasted again.
    @Test func thoughtThrownAwayBeforeItsPasteIsNotPastedAgain() {
        var memory = PasteAgain()
        memory.delivered(id: 1, text: "First.", outcome: .pasted)
        memory.started(id: 2)
        memory.thrownAway(id: 2)
        #expect(memory.text(waiting: nil, newest: row(2)) == nil)
        // Read from the database after a restart: the row says discarded.
        #expect(PasteAgain().text(waiting: nil, newest: row(2, status: "discarded")) == nil)
    }
}
