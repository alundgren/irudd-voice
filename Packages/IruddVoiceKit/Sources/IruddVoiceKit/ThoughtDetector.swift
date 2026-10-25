/// Settings for finding where a thought starts and ends in the mic's audio.
/// The numbers come from testing the BOYA BY-GM18CU
/// (docs/hardware/boya-by-gm18cu.md).
public struct ThoughtSettings: Sendable, Equatable {
    /// Exact-zero audio this long means the mic's mute button is on.
    /// Speech never produced a zero run over 20 ms; the button's own blip is 33 ms.
    public var muteZeroRun: Double = 0.25
    /// Ignore mutes this long after the stream opens. The BOYA sends ~0.6 s
    /// of zeros at startup even when it isn't muted.
    public var startupIgnore: Double = 1.0
    /// How much audio before the start signal is kept, so the first word
    /// isn't cut off.
    public var preRoll: Double = 2.0
    /// A thought started with the hotkey ends after this much silence.
    /// Thoughts started by unmuting only end on mute or the hotkey, so you
    /// can pause to think.
    public var silenceTimeout: Double = 5.0
    /// Peak level under which a 100 ms window counts as silence (about -45 dBFS).
    public var silenceLevel: Float = 0.0056
    public var silenceWindow: Double = 0.1

    public init() {}
}

public enum ThoughtStartReason: String, Sendable {
    case unmute
    case hotkey
}

public enum ThoughtEndReason: String, Sendable {
    case muteButton
    case hotkey
    case silence
    case micLost
    case micChanged
    case switchedOff
    case thrownAway

    public var description: String {
        switch self {
        case .muteButton: "mute button"
        case .hotkey: "hotkey"
        case .silence: "5 s of silence"
        case .micLost: "mic unplugged"
        case .micChanged: "switched mic"
        case .switchedOff: "switched off"
        case .thrownAway: "thrown away"
        }
    }
}

/// One finished thought: mono audio at the mic's sample rate.
public struct CapturedThought: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    /// Stream positions in samples since the stream opened.
    public let firstSample: Int64
    public let signalSample: Int64
    public let startReason: ThoughtStartReason
    public let endReason: ThoughtEndReason

    public init(samples: [Float], sampleRate: Double, firstSample: Int64, signalSample: Int64,
                startReason: ThoughtStartReason, endReason: ThoughtEndReason) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.firstSample = firstSample
        self.signalSample = signalSample
        self.startReason = startReason
        self.endReason = endReason
    }

    public var duration: Double { Double(samples.count) / sampleRate }
    /// Seconds of audio kept from before the start signal.
    public var preRollDuration: Double { Double(signalSample - firstSample) / sampleRate }
}

public enum ThoughtEvent: Sendable {
    /// A thought started. `preRoll` is the audio kept from before the start.
    case started(ThoughtStartReason, preRoll: [Float])
    /// More audio for the thought in progress, for live recognition. It can
    /// run a little past the thought's end (until a mute is recognised); the
    /// `ended` thought's samples are the exact audio.
    case audio([Float])
    case ended(CapturedThought)
}

/// Turns a stream of mic samples into thoughts. Not thread-safe: call it from
/// one queue. Create a new one whenever the stream (re)opens.
public final class ThoughtDetector {
    public let sampleRate: Double
    public let settings: ThoughtSettings

    /// Samples seen since the stream opened.
    public private(set) var position: Int64 = 0
    /// True once a mute (a long exact-zero run) has been seen and not yet
    /// followed by sound.
    public private(set) var isMuted = false
    public var isInThought: Bool { thought != nil }

    private let muteRunSamples: Int
    private let startupSamples: Int64
    private let silenceWindowSamples: Int
    private let silenceTimeoutSamples: Int
    private var preRoll: SampleRing

    private var zeroRun = 0
    private var zeroRunStart: Int64 = 0

    private struct Thought {
        var samples: [Float]
        var firstSample: Int64
        var signalSample: Int64
        var reason: ThoughtStartReason
        var windowPeak: Float = 0
        var windowCount = 0
        var silentSamples = 0
        var silenceStart: Int64 = 0
    }
    private var thought: Thought?
    /// Audio added to the thought during the current `process` call, not yet
    /// sent as an `.audio` event.
    private var unsent: [Float] = []

    public init(sampleRate: Double, settings: ThoughtSettings = ThoughtSettings()) {
        self.sampleRate = sampleRate
        self.settings = settings
        muteRunSamples = max(1, Int(settings.muteZeroRun * sampleRate))
        startupSamples = Int64(settings.startupIgnore * sampleRate)
        silenceWindowSamples = max(1, Int(settings.silenceWindow * sampleRate))
        silenceTimeoutSamples = Int(settings.silenceTimeout * sampleRate)
        preRoll = SampleRing(capacity: max(1, Int(settings.preRoll * sampleRate)))
    }

    public func process(_ samples: some Collection<Float>) -> [ThoughtEvent] {
        var events: [ThoughtEvent] = []
        for sample in samples {
            let pos = position

            if sample == 0 {
                if zeroRun == 0 { zeroRunStart = pos }
                zeroRun += 1
            } else {
                if isMuted {
                    isMuted = false
                    if thought == nil {
                        events.append(start(at: pos, reason: .unmute))
                    }
                }
                zeroRun = 0
            }

            // Mutate the thought in place. Copying it out (`if var current =
            // thought`) would copy its whole sample array on every sample,
            // which made long thoughts slower and slower.
            if thought != nil {
                thought!.samples.append(sample)
                unsent.append(sample)
                trackSilence(sample: sample, pos: pos)
                if thought!.reason == .hotkey, thought!.silentSamples >= silenceTimeoutSamples {
                    events += end(at: thought!.silenceStart, reason: .silence)
                }
            }

            if !isMuted, zeroRun >= muteRunSamples, pos >= startupSamples {
                isMuted = true
                if thought != nil {
                    events += end(at: zeroRunStart, reason: .muteButton)
                }
            }

            preRoll.append(sample)
            position += 1
        }
        flushUnsent(into: &events)
        return events
    }

    /// The start/stop hotkey: starts a thought, or ends the current one.
    public func hotkey() -> [ThoughtEvent] {
        if thought != nil {
            return end(at: position, reason: .hotkey)
        }
        return [start(at: position, reason: .hotkey)]
    }

    /// Ends the current thought, keeping what was heard so far.
    public func finish(_ reason: ThoughtEndReason) -> [ThoughtEvent] {
        guard thought != nil else { return [] }
        return end(at: position, reason: reason)
    }

    private func start(at pos: Int64, reason: ThoughtStartReason) -> ThoughtEvent {
        let before = preRoll.contents()
        thought = Thought(
            samples: before,
            firstSample: pos - Int64(before.count),
            signalSample: pos,
            reason: reason,
            silenceStart: pos
        )
        return .started(reason, preRoll: before)
    }

    /// Ends the thought at stream position `endPos`, dropping anything after
    /// it. Returns the last `.audio` (if any) and the `.ended` event.
    private func end(at endPos: Int64, reason: ThoughtEndReason) -> [ThoughtEvent] {
        var events: [ThoughtEvent] = []
        flushUnsent(into: &events)
        var current = thought!
        thought = nil
        let keep = Int(max(0, min(Int64(current.samples.count), endPos - current.firstSample)))
        current.samples.removeLast(current.samples.count - keep)
        events.append(.ended(CapturedThought(
            samples: current.samples,
            sampleRate: sampleRate,
            firstSample: current.firstSample,
            signalSample: current.signalSample,
            startReason: current.reason,
            endReason: reason
        )))
        return events
    }

    private func flushUnsent(into events: inout [ThoughtEvent]) {
        guard !unsent.isEmpty else { return }
        events.append(.audio(unsent))
        unsent.removeAll(keepingCapacity: true)
    }

    private func trackSilence(sample: Float, pos: Int64) {
        thought!.windowPeak = max(thought!.windowPeak, abs(sample))
        thought!.windowCount += 1
        guard thought!.windowCount == silenceWindowSamples else { return }
        if thought!.windowPeak < settings.silenceLevel {
            if thought!.silentSamples == 0 {
                thought!.silenceStart = pos + 1 - Int64(silenceWindowSamples)
            }
            thought!.silentSamples += silenceWindowSamples
        } else {
            thought!.silentSamples = 0
        }
        thought!.windowPeak = 0
        thought!.windowCount = 0
    }
}

/// Keeps the most recent `capacity` samples.
struct SampleRing {
    private var storage: [Float]
    private var next = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = [Float](repeating: 0, count: capacity)
    }

    mutating func append(_ sample: Float) {
        storage[next] = sample
        next = (next + 1) % storage.count
        count = min(count + 1, storage.count)
    }

    func contents() -> [Float] {
        if count < storage.count { return Array(storage[0..<count]) }
        return Array(storage[next...] + storage[..<next])
    }
}
