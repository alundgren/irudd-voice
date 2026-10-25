import Testing
@testable import IruddVoiceKit

/// Synthetic audio at a low sample rate so the arithmetic is easy to follow:
/// 1000 samples per second, so 1 sample = 1 ms.
struct ThoughtDetectorTests {
    let rate = 1000.0

    func detector(_ change: (inout ThoughtSettings) -> Void = { _ in }) -> ThoughtDetector {
        var settings = ThoughtSettings()
        change(&settings)
        return ThoughtDetector(sampleRate: rate, settings: settings)
    }

    func speech(_ ms: Int, level: Float = 0.3) -> [Float] {
        (0..<ms).map { $0.isMultiple(of: 2) ? level : -level }
    }

    func zeros(_ ms: Int) -> [Float] { [Float](repeating: 0, count: ms) }

    func ended(_ events: [ThoughtEvent]) -> CapturedThought? {
        for case .ended(let thought) in events { return thought }
        return nil
    }

    func started(_ events: [ThoughtEvent]) -> ThoughtStartReason? {
        for case .started(let reason, _) in events { return reason }
        return nil
    }

    /// Everything streamed for live recognition: pre-roll, then audio events.
    func streamed(_ events: [ThoughtEvent]) -> [Float] {
        var out: [Float] = []
        for event in events {
            switch event {
            case .started(_, let preRoll): out += preRoll
            case .audio(let samples): out += samples
            case .ended: break
            }
        }
        return out
    }

    @Test func startupZerosAreNotAMute() {
        let d = detector()
        _ = d.process(zeros(600))   // the BOYA's ~0.6 s of zeros at startup
        let events = d.process(speech(2000))
        #expect(events.isEmpty)
        #expect(!d.isMuted)
        #expect(!d.isInThought)
    }

    @Test func mutedAtStartIsNoticedAfterTheStartupWindow() {
        let d = detector()
        _ = d.process(zeros(3000))
        #expect(d.isMuted)
        let events = d.process(speech(100))
        #expect(started(events) == .unmute)
    }

    @Test func unmuteStartsAndMuteEnds() {
        let d = detector()
        _ = d.process(speech(1500))
        _ = d.process(zeros(3000))          // mute
        #expect(d.isMuted)
        let start = d.process(speech(4000)) // unmute and talk
        #expect(started(start) == .unmute)
        var events = d.process(zeros(33))    // the button's blip
        events += d.process(speech(50))
        events += d.process(zeros(400))      // mute again
        let thought = try! #require(ended(events))
        #expect(thought.startReason == .unmute)
        #expect(thought.endReason == .muteButton)
        // 2 s pre-roll + 4000 ms speech + 33 blip + 50 speech, cut where the zeros began.
        #expect(thought.samples.count == 2000 + 4000 + 33 + 50)
        #expect(thought.preRollDuration == 2.0)
        #expect(thought.samples.last != 0)
    }

    @Test func speechRightAfterUnmuteIsKept() {
        let d = detector()
        _ = d.process(speech(1500))
        _ = d.process(zeros(3000))
        // Unmute: 50 ms of quiet-but-not-zero sound, then speech.
        _ = d.process([Float](repeating: 0.001, count: 50))
        _ = d.process(speech(1000, level: 0.5))
        let thought = try! #require(ended(d.process(zeros(300))))
        let loud = thought.samples.filter { abs($0) == 0.5 }.count
        #expect(loud == 1000)
        #expect(thought.samples.count == 2000 + 50 + 1000)
    }

    @Test func shortZeroRunsDuringSpeechDontEndAThought() {
        let d = detector()
        _ = d.process(speech(1500))
        _ = d.process(zeros(3000))
        _ = d.process(speech(500))
        var events: [ThoughtEvent] = []
        for _ in 0..<20 {
            events += d.process(zeros(30))
            events += d.process(speech(200))
        }
        #expect(ended(events) == nil)
        #expect(d.isInThought)
    }

    @Test func pausingInAnUnmutedThoughtDoesNotEndIt() {
        let d = detector()
        _ = d.process(speech(1500))
        _ = d.process(zeros(3000))
        _ = d.process(speech(500))
        let events = d.process([Float](repeating: 0.0001, count: 10_000)) // 10 s of near-silence
        #expect(ended(events) == nil)
    }

    @Test func hotkeyStartsWithPreRollAndStops() {
        let d = detector()
        _ = d.process(speech(3000))
        #expect(started(d.hotkey()) == .hotkey)
        _ = d.process(speech(1000))
        let thought = try! #require(ended(d.hotkey()))
        #expect(thought.startReason == .hotkey)
        #expect(thought.endReason == .hotkey)
        #expect(thought.samples.count == 2000 + 1000)
    }

    @Test func hotkeyThoughtEndsAfterFiveSecondsOfSilence() {
        let d = detector()
        _ = d.process(speech(3000))
        _ = d.hotkey()
        _ = d.process(speech(1000))
        let events = d.process([Float](repeating: 0.001, count: 6000))
        let thought = try! #require(ended(events))
        #expect(thought.endReason == .silence)
        // Cut where the silence started.
        #expect(thought.samples.count == 2000 + 1000)
    }

    @Test func muteEndsAHotkeyThought() {
        let d = detector()
        _ = d.process(speech(3000))
        _ = d.hotkey()
        _ = d.process(speech(500))
        let thought = try! #require(ended(d.process(zeros(300))))
        #expect(thought.endReason == .muteButton)
    }

    @Test func finishKeepsWhatWasHeard() {
        let d = detector()
        _ = d.process(speech(1500))
        _ = d.process(zeros(3000))
        _ = d.process(speech(700))
        let thought = try! #require(ended(d.finish(.micLost)))
        #expect(thought.endReason == .micLost)
        #expect(thought.samples.count == 2000 + 700)
        #expect(d.finish(.micLost).isEmpty)
    }

    @Test func streamedAudioStartsWithTheThoughtAndCoversIt() {
        let d = detector()
        _ = d.process(speech(1500))
        _ = d.process(zeros(3000))
        var events = d.process(speech(700))
        events += d.process(speech(300, level: 0.2))
        events += d.process(zeros(400))
        let thought = try! #require(ended(events))
        let live = streamed(events)
        #expect(live.count >= thought.samples.count)
        #expect(Array(live.prefix(thought.samples.count)) == thought.samples)
    }

    @Test func eventsComeInOrder() {
        let d = detector()
        _ = d.process(speech(1500))
        _ = d.process(zeros(3000))
        // Start, talk, mute: all inside one batch.
        let events = d.process(speech(500) + zeros(400))
        guard events.count == 3,
              case .started = events[0], case .audio = events[1], case .ended = events[2]
        else {
            Issue.record("unexpected events: \(events)")
            return
        }
    }

    @Test func preRollIsShorterRightAfterTheStreamOpens() {
        let d = detector()
        _ = d.process(speech(300))
        _ = d.hotkey()
        _ = d.process(speech(100))
        let thought = try! #require(ended(d.hotkey()))
        #expect(thought.firstSample == 0)
        #expect(thought.samples.count == 400)
    }
}
