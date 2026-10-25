import AudioToolbox
import CoreAudio
import Foundation
import os

public enum CaptureError: Error, CustomStringConvertible {
    case cannotOpen(String)

    public var description: String {
        switch self {
        case .cannotOpen(let reason): reason
        }
    }
}

/// Opens one device with a HAL audio unit (AUHAL) bound by
/// kAudioOutputUnitProperty_CurrentDevice, and turns its audio into thoughts.
///
/// The audio thread only copies samples into a buffer. A timer on a serial
/// queue moves them into the `ThoughtDetector` every 20 ms, and thought
/// events are delivered on the main actor.
@MainActor
public final class LiveCapture: CaptureStream {
    /// Thought started or ended.
    public var onEvent: (@MainActor (ThoughtEvent) -> Void)?
    /// The stream needs reopening: the sample rate changed or audio stopped
    /// arriving.
    public var onTrouble: (@MainActor (String) -> Void)?
    /// Peak level of the last 100 ms, for a level meter.
    public var onLevel: (@MainActor (Float) -> Void)?

    public private(set) var runningDeviceID: AudioDeviceID?
    /// Sample rate of the open stream (the mic's own rate).
    public var sampleRate: Double? { engine?.sampleRate }
    private var engine: CaptureEngine?
    private let settings: ThoughtSettings

    public init(settings: ThoughtSettings = ThoughtSettings()) {
        self.settings = settings
    }

    public func start(device: AudioDeviceInfo) throws {
        // Messages go through the main queue in order, so a thought's start
        // is never handled after its end.
        let engine = try CaptureEngine(deviceID: device.id, settings: settings) { [weak self] message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.deliver(message) }
            }
        }
        self.engine = engine
        runningDeviceID = device.id
    }

    public func stop(reason: ThoughtEndReason) {
        guard let engine else { return }
        let events = engine.stop(reason: reason)
        self.engine = nil
        runningDeviceID = nil
        // Queued behind any messages the engine already sent, to keep the order.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                for event in events { self?.onEvent?(event) }
            }
        }
    }

    /// The start/stop hotkey.
    public func hotkey() {
        engine?.hotkey()
    }

    private func deliver(_ message: CaptureEngine.Message) {
        switch message {
        case .event(let event): onEvent?(event)
        case .trouble(let reason): onTrouble?(reason)
        case .level(let peak): onLevel?(peak)
        }
    }
}

/// The parts that run off the main actor. Everything except the audio
/// callback runs on `queue`.
private final class CaptureEngine: @unchecked Sendable {
    enum Message: Sendable {
        case event(ThoughtEvent)
        case trouble(String)
        case level(Float)
    }

    private let deviceID: AudioDeviceID
    private let queue = DispatchQueue(label: "irudd-voice.capture", qos: .userInitiated)
    private let send: @Sendable (Message) -> Void
    private let detector: ThoughtDetector
    private let unit: AudioUnit
    private let buffers: UnsafeMutableAudioBufferListPointer
    private let maxFrames = 8192
    private let channels: Int
    private let ring: SharedRing
    private let callbackState: CallbackState
    private var timer: DispatchSourceTimer?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private let openedAt = Date()
    private var lastAudioAt = Date()
    private var reportedStall = false
    private var levelPeak: Float = 0
    private var levelCount = 0
    let sampleRate: Double

    init(deviceID: AudioDeviceID, settings: ThoughtSettings, send: @escaping @Sendable (Message) -> Void) throws {
        self.deviceID = deviceID
        self.send = send

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CaptureError.cannotOpen("HAL audio unit not found")
        }
        var created: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &created), "create audio unit")
        guard let unit = created else { throw CaptureError.cannotOpen("create audio unit") }
        self.unit = unit

        var on: UInt32 = 1
        var off: UInt32 = 0
        var device = deviceID
        var maxSlice = UInt32(maxFrames)
        var deviceFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        do {
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4),
                           "enable input")
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4),
                           "disable output")
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "bind device")
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                                &maxSlice, 4), "set buffer size")
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                                &deviceFormat, &formatSize), "read device format")
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }

        sampleRate = deviceFormat.mSampleRate
        channels = max(1, Int(deviceFormat.mChannelsPerFrame))
        detector = ThoughtDetector(sampleRate: sampleRate, settings: settings)
        ring = SharedRing(capacity: Int(sampleRate * 5))

        // Ask for 32-bit float, one buffer per channel, at the device's own
        // rate (an input AUHAL can't convert rates).
        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)

        buffers = AudioBufferList.allocate(maximumBuffers: channels)
        for index in 0..<channels {
            buffers[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(maxFrames * 4),
                                         mData: UnsafeMutableRawPointer.allocate(byteCount: maxFrames * 4, alignment: 16))
        }
        callbackState = CallbackState(unit: unit, buffers: buffers, channels: channels, maxFrames: maxFrames, ring: ring)

        var callback = AURenderCallbackStruct(inputProc: captureCallback,
                                              inputProcRefCon: Unmanaged.passUnretained(callbackState).toOpaque())
        do {
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                                &clientFormat, formatSize), "set format")
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                           "set callback")
            try Self.check(AudioUnitInitialize(unit), "initialize")
            try Self.check(AudioOutputUnitStart(unit), "start")
        } catch {
            // Every property is set by now, so deinit runs and frees the buffers.
            AudioComponentInstanceDispose(unit)
            throw error
        }

        watchSampleRate()
        startTimer()
    }

    deinit {
        Self.free(buffers)
    }

    func hotkey() {
        queue.async { [self] in
            drain()
            for event in detector.hotkey() { send(.event(event)) }
        }
    }

    /// Stops the audio unit and returns the events from ending a thought in
    /// progress, so they're handled before anything else happens.
    func stop(reason: ThoughtEndReason) -> [ThoughtEvent] {
        AudioOutputUnitStop(unit)
        unwatchSampleRate()
        return queue.sync {
            timer?.cancel()
            timer = nil
            var events = drain()
            events += detector.finish(reason)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            return events
        }
    }

    // MARK: - Queue work

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for event in drain() { send(.event(event)) }
            checkStall()
        }
        timer.resume()
        self.timer = timer
    }

    @discardableResult
    private func drain() -> [ThoughtEvent] {
        let samples = ring.takeAll()
        guard !samples.isEmpty else { return [] }
        lastAudioAt = Date()
        reportedStall = false
        updateLevel(samples)
        return detector.process(samples)
    }

    private func updateLevel(_ samples: [Float]) {
        let window = Int(sampleRate / 10)
        for sample in samples {
            levelPeak = max(levelPeak, abs(sample))
            levelCount += 1
            if levelCount >= window {
                send(.level(levelPeak))
                levelPeak = 0
                levelCount = 0
            }
        }
    }

    /// No audio for 2 s (after the first second) means the device stopped
    /// sending. Ask for the stream to be reopened.
    private func checkStall() {
        let now = Date()
        guard !reportedStall, now.timeIntervalSince(openedAt) > 1,
              now.timeIntervalSince(lastAudioAt) > 2 else { return }
        reportedStall = true
        send(.trouble("No audio arrived for 2 seconds"))
    }

    // MARK: - Device sample rate

    private func watchSampleRate() {
        let send = self.send
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            send(.trouble("The mic's sample rate changed"))
        }
        var address = CoreAudioDevices.address(kAudioDevicePropertyNominalSampleRate)
        if AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block) == noErr {
            rateListener = block
        }
    }

    private func unwatchSampleRate() {
        guard let block = rateListener else { return }
        var address = CoreAudioDevices.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
        rateListener = nil
    }

    // MARK: - Helpers

    private static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw CaptureError.cannotOpen("\(what) failed (\(status))") }
    }

    private static func free(_ buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers { buffer.mData?.deallocate() }
        buffers.unsafeMutablePointer.deallocate()
    }
}

/// What the audio callback needs. Passed through the callback's refCon,
/// because a C callback can't capture Swift context.
private final class CallbackState: @unchecked Sendable {
    let unit: AudioUnit
    let buffers: UnsafeMutableAudioBufferListPointer
    let channels: Int
    let maxFrames: Int
    let ring: SharedRing
    let mono: UnsafeMutablePointer<Float>

    init(unit: AudioUnit, buffers: UnsafeMutableAudioBufferListPointer, channels: Int, maxFrames: Int, ring: SharedRing) {
        self.unit = unit
        self.buffers = buffers
        self.channels = channels
        self.maxFrames = maxFrames
        self.ring = ring
        mono = .allocate(capacity: maxFrames)
    }

    deinit { mono.deallocate() }
}

/// Runs on CoreAudio's real-time thread: render the input, mix it to mono,
/// copy it into the ring. No allocation, no waiting on the main thread.
private func captureCallback(
    refCon: UnsafeMutableRawPointer,
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    timestamp: UnsafePointer<AudioTimeStamp>,
    bus: UInt32,
    frames: UInt32,
    data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let state = Unmanaged<CallbackState>.fromOpaque(refCon).takeUnretainedValue()
    let count = Int(frames)
    guard count <= state.maxFrames else { return kAudioUnitErr_TooManyFramesToProcess }
    for index in 0..<state.channels {
        state.buffers[index].mDataByteSize = frames * 4
    }
    let status = AudioUnitRender(state.unit, flags, timestamp, bus, frames, state.buffers.unsafeMutablePointer)
    guard status == noErr else { return status }

    let first = state.buffers[0].mData!.assumingMemoryBound(to: Float.self)
    if state.channels == 1 {
        state.mono.update(from: first, count: count)
    } else {
        // Average the channels. Exact zeros on every channel stay exact zeros.
        let scale = 1 / Float(state.channels)
        for frame in 0..<count {
            var sum: Float = 0
            for channel in 0..<state.channels {
                sum += state.buffers[channel].mData!.assumingMemoryBound(to: Float.self)[frame]
            }
            state.mono[frame] = sum * scale
        }
    }
    state.ring.write(state.mono, count: count)
    return noErr
}

/// A fixed-size buffer shared by the audio thread (writer) and the capture
/// queue (reader). If the reader falls more than 5 s behind, new audio is
/// dropped rather than blocking the audio thread.
private final class SharedRing: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var start = 0
    private var count = 0
    private let lock = OSAllocatedUnfairLock()

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
    }

    deinit { storage.deallocate() }

    func write(_ samples: UnsafePointer<Float>, count incoming: Int) {
        lock.withLockUnchecked {
            let space = capacity - count
            let n = min(incoming, space)
            for i in 0..<n {
                storage[(start + count + i) % capacity] = samples[i]
            }
            count += n
        }
    }

    func takeAll() -> [Float] {
        lock.withLockUnchecked {
            var out = [Float](repeating: 0, count: count)
            for i in 0..<count {
                out[i] = storage[(start + i) % capacity]
            }
            start = (start + count) % capacity
            count = 0
            return out
        }
    }
}
