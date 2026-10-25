// boya-probe: find out what a USB mic's mute button does on macOS.
//
// Watches one input device for the signals a mute button could produce:
// exact-zero samples, a CoreAudio mute/volume change, the device going away,
// or HID button presses. Logs everything with timestamps. No windows.
//
// Usage:
//   boya-probe --list
//   boya-probe [--name BY-GM18CU | --uid UID] [--seconds 90]

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import IOKit.hid

// MARK: - Logging

let startTime = Date()
var logFile: FileHandle?

func log(_ message: String) {
    let t = String(format: "%7.3f", Date().timeIntervalSince(startTime))
    let line = "[\(t)] \(message)\n"
    FileHandle.standardOutput.write(Data(line.utf8))
    logFile?.write(Data(line.utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// MARK: - CoreAudio helpers

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func getValue<T: BitwiseCopyable>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) -> T? {
    var addr = addr
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    return status == noErr ? value : nil
}

func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
    guard status == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func allDevices() -> [AudioDeviceID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func inputChannelCount(_ device: AudioDeviceID) -> Int {
    var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

struct InputDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let modelUID: String
    let channels: Int
    let sampleRate: Double
}

func inputDevices() -> [InputDevice] {
    allDevices().compactMap { id in
        let channels = inputChannelCount(id)
        guard channels > 0 else { return nil }
        return InputDevice(
            id: id,
            name: getString(id, kAudioObjectPropertyName) ?? "?",
            uid: getString(id, kAudioDevicePropertyDeviceUID) ?? "?",
            modelUID: getString(id, kAudioDevicePropertyModelUID) ?? "?",
            channels: channels,
            sampleRate: getValue(id, address(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0
        )
    }
}

func describe(_ d: InputDevice) -> String {
    "\(d.name)  uid=\(d.uid)  model=\(d.modelUID)  id=\(d.id)  channels=\(d.channels)  rate=\(Int(d.sampleRate))"
}

// MARK: - Arguments

var args = Array(CommandLine.arguments.dropFirst())
func takeOption(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

if args.contains("--help") || args.contains("-h") {
    print("usage: boya-probe --list\n       boya-probe [--name BY-GM18CU | --uid UID] [--seconds 90]")
    exit(0)
}

if args.contains("--list") {
    for d in inputDevices() { print(describe(d)) }
    exit(0)
}

let wantedUID = takeOption("--uid")
let wantedName = takeOption("--name") ?? "BY-GM18CU"
let seconds = Double(takeOption("--seconds") ?? "90") ?? 90

// MARK: - Pick the device

let devices = inputDevices()
let picked: InputDevice
if let wantedUID {
    guard let d = devices.first(where: { $0.uid == wantedUID }) else { fail("no input device with uid \(wantedUID). Run --list.") }
    picked = d
} else {
    guard let d = devices.first(where: { $0.name.localizedCaseInsensitiveContains(wantedName) }) else {
        fail("no input device named like \"\(wantedName)\". Is it plugged in? Run --list.")
    }
    picked = d
}
let deviceID = picked.id

// MARK: - Mic permission

// Without mic permission macOS delivers silence (all zeros), which would look
// exactly like a mute button. Check first so we don't draw the wrong conclusion.
switch AVCaptureDevice.authorizationStatus(for: .audio) {
case .authorized:
    break
case .notDetermined:
    print("macOS will now ask if this terminal may use the microphone. Click Allow, then run the probe again.")
    let done = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .audio) { _ in done.signal() }
    done.wait()
    exit(0)
default:
    fail("""
    this terminal is not allowed to use the microphone, so every sample would be zero.
    Open System Settings > Privacy & Security > Microphone, turn on your terminal app, restart the terminal, and run again.
    """)
}

// MARK: - Log file

let stamp = ISO8601DateFormatter().string(from: startTime).replacingOccurrences(of: ":", with: "-")
let logPath = FileManager.default.currentDirectoryPath + "/boya-probe-\(stamp).log"
FileManager.default.createFile(atPath: logPath, contents: nil)
logFile = FileHandle(forWritingAtPath: logPath)

log("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
log("device: \(describe(picked))")
log("all inputs:")
for d in devices { log("  \(describe(d))") }

// MARK: - Audio sample stats (shared with the audio thread)

final class Stats: @unchecked Sendable {
    let lock: UnsafeMutablePointer<os_unfair_lock> = { let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1); p.initialize(to: os_unfair_lock()); return p }()
    var peak: Float = 0
    var samples = 0
    var zeroSamples = 0
    var zeroRun = 0            // current run of exact-zero samples, in frames
    var longestZeroRun = 0
    var finishedRuns: [(start: Date, frames: Int)] = []
    var runStart: Date?
    var callbacks = 0
}
let stats = Stats()
var sampleRate = picked.sampleRate > 0 ? picked.sampleRate : 48000

// Zero runs shorter than this are ignored (real audio crosses zero often,
// but never sits at exactly 0.0 for a whole millisecond chunk).
let minRunMs = 20.0

// MARK: - AUHAL bound to the exact device

var desc = AudioComponentDescription(
    componentType: kAudioUnitType_Output,
    componentSubType: kAudioUnitSubType_HALOutput,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0, componentFlagsMask: 0)
guard let component = AudioComponentFindNext(nil, &desc) else { fail("HAL output unit not found") }
var unitOpt: AudioUnit?
guard AudioComponentInstanceNew(component, &unitOpt) == noErr, let unit = unitOpt else { fail("could not create audio unit") }

func check(_ status: OSStatus, _ what: String) {
    if status != noErr { fail("\(what) failed (\(status))") }
}

var one: UInt32 = 1
var zero: UInt32 = 0
check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4), "enable input")
check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4), "disable output")
var dev = deviceID
check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                           UInt32(MemoryLayout<AudioDeviceID>.size)), "bind device")

var deviceFormat = AudioStreamBasicDescription()
var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &formatSize), "read device format")
sampleRate = deviceFormat.mSampleRate
let channels = max(1, Int(deviceFormat.mChannelsPerFrame))
log("device format: \(Int(deviceFormat.mSampleRate)) Hz, \(channels) ch, \(deviceFormat.mBitsPerChannel) bit")

var clientFormat = AudioStreamBasicDescription(
    mSampleRate: deviceFormat.mSampleRate,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
    mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientFormat, formatSize), "set client format")

let maxFrames = 4096
let bufferList = AudioBufferList.allocate(maximumBuffers: channels)
for i in 0..<channels {
    bufferList[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(maxFrames * 4),
                                mData: UnsafeMutableRawPointer.allocate(byteCount: maxFrames * 4, alignment: 16))
}

// The callback is a C function pointer, so it can't capture globals that
// Swift treats as context. Everything it needs comes in through refCon.
final class Capture {
    let unit: AudioUnit
    let buffers: UnsafeMutableAudioBufferListPointer
    let stats: Stats
    let sampleRate: Double
    init(unit: AudioUnit, buffers: UnsafeMutableAudioBufferListPointer, stats: Stats, sampleRate: Double) {
        self.unit = unit; self.buffers = buffers; self.stats = stats; self.sampleRate = sampleRate
    }
}
let capture = Capture(unit: unit, buffers: bufferList, stats: stats, sampleRate: sampleRate)

let inputCallback: AURenderCallback = { refCon, flags, timestamp, bus, frames, _ in
    let capture = Unmanaged<Capture>.fromOpaque(refCon).takeUnretainedValue()
    let bufferList = capture.buffers, stats = capture.stats, sampleRate = capture.sampleRate
    for i in 0..<bufferList.count { bufferList[i].mDataByteSize = frames * 4 }
    let status = AudioUnitRender(capture.unit, flags, timestamp, bus, frames, bufferList.unsafeMutablePointer)
    guard status == noErr else { return status }

    os_unfair_lock_lock(stats.lock)
    defer { os_unfair_lock_unlock(stats.lock) }
    stats.callbacks += 1
    let minRunFrames = Int(sampleRate * minRunMs / 1000)
    for f in 0..<Int(frames) {
        // A frame is "zero" only if every channel is exactly 0.0.
        var allZero = true
        for c in 0..<bufferList.count {
            let s = bufferList[c].mData!.assumingMemoryBound(to: Float.self)[f]
            let a = abs(s)
            if a > stats.peak { stats.peak = a }
            if s != 0 { allZero = false }
        }
        stats.samples += 1
        if allZero {
            stats.zeroSamples += 1
            stats.zeroRun += 1
            if stats.zeroRun == minRunFrames { stats.runStart = Date() }
        } else if stats.zeroRun > 0 {
            if stats.zeroRun >= minRunFrames {
                stats.finishedRuns.append((stats.runStart ?? Date(), stats.zeroRun))
            }
            stats.longestZeroRun = max(stats.longestZeroRun, stats.zeroRun)
            stats.zeroRun = 0
            stats.runStart = nil
        }
    }
    return noErr
}

var callbackStruct = AURenderCallbackStruct(inputProc: inputCallback, inputProcRefCon: Unmanaged.passUnretained(capture).toOpaque())
check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                           &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input callback")
check(AudioUnitInitialize(unit), "initialize audio unit")

// MARK: - CoreAudio property listeners

var propertyEvents = 0
let listenerQueue = DispatchQueue.main

func scalar(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> String {
    let addr = address(selector, kAudioObjectPropertyScopeInput, element)
    var a = addr
    guard AudioObjectHasProperty(deviceID, &a) else { return "n/a" }
    if selector == kAudioDevicePropertyMute || selector == kAudioDevicePropertyDataSource {
        return getValue(deviceID, addr, UInt32(0)).map(String.init) ?? "?"
    }
    return getValue(deviceID, addr, Float32(0)).map { String(format: "%.3f", $0) } ?? "?"
}

func watch(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ label: String, _ read: @escaping () -> String) {
    var a = addr
    guard AudioObjectHasProperty(object, &a) else {
        log("property \(label): not present")
        return
    }
    log("property \(label): \(read())")
    let status = AudioObjectAddPropertyListenerBlock(object, &a, listenerQueue) { _, _ in
        propertyEvents += 1
        log("EVENT property \(label) changed -> \(read())")
    }
    if status != noErr { log("could not listen to \(label) (\(status))") }
}

for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1] {
    watch(deviceID, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput, element), "mute[input,\(element)]") {
        scalar(kAudioDevicePropertyMute, element)
    }
    watch(deviceID, address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, element), "volume[input,\(element)]") {
        scalar(kAudioDevicePropertyVolumeScalar, element)
    }
}
watch(deviceID, address(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeInput), "data source") {
    scalar(kAudioDevicePropertyDataSource, kAudioObjectPropertyElementMain)
}
watch(deviceID, address(kAudioDevicePropertyDeviceIsAlive), "is alive") {
    getValue(deviceID, address(kAudioDevicePropertyDeviceIsAlive), UInt32(0)).map(String.init) ?? "gone"
}
watch(deviceID, address(kAudioDevicePropertyNominalSampleRate), "sample rate") {
    getValue(deviceID, address(kAudioDevicePropertyNominalSampleRate), Float64(0)).map { String(Int($0)) } ?? "?"
}
watch(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices), "device list") {
    inputDevices().map(\.name).joined(separator: ", ")
}
watch(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultInputDevice), "default input") {
    let id = getValue(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultInputDevice), AudioDeviceID(0)) ?? 0
    return getString(id, kAudioObjectPropertyName) ?? "\(id)"
}

// MARK: - HID buttons on the same USB device

// The BY-GM18CU also shows up as a USB "consumer control" device (the kind
// that sends volume and play/pause keys). Log anything it sends.
let hid = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(hid, [kIOHIDProductKey: picked.name] as CFDictionary)


// Device matching by product name alone also let through the Mac's own
// sensors (usage page 0x20), so each value is checked against the device it
// came from. The C callback can't capture context; the name and usage table
// come in through the context pointer.
final class HIDContext {
    let productName: String
    var events = 0
    init(productName: String) { self.productName = productName }
}
let hidContext = HIDContext(productName: picked.name)

IOHIDManagerRegisterInputValueCallback(hid, { context, _, _, value in
    let ctx = Unmanaged<HIDContext>.fromOpaque(context!).takeUnretainedValue()
    let element = IOHIDValueGetElement(value)
    let device = IOHIDElementGetDevice(element)
    let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
    guard product == ctx.productName else { return }
    let page = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let v = IOHIDValueGetIntegerValue(value)
    let names: [UInt32: String] = [
        0xE2: "Mute", 0xE9: "Volume Up", 0xEA: "Volume Down", 0xCD: "Play/Pause",
        0xCF: "Voice Command", 0xB5: "Next Track", 0xB6: "Previous Track",
    ]
    let name = page == 0x0C ? (names[usage] ?? "") : ""
    ctx.events += 1
    log(String(format: "EVENT hid %@ page=0x%02X usage=0x%02X %@ value=%ld", product, page, usage, name, v))
}, Unmanaged.passUnretained(hidContext).toOpaque())

let hidOpen = IOHIDManagerOpen(hid, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
if hidOpen == kIOReturnSuccess {
    let all = (IOHIDManagerCopyDevices(hid) as? Set<IOHIDDevice>) ?? []
    let mine = all.filter { (IOHIDDeviceGetProperty($0, kIOHIDProductKey as CFString) as? String) == picked.name }
    log("hid: watching \(mine.count) HID interface(s) named \(picked.name)")
} else {
    log(String(format: "hid: could not open (0x%08X). Buttons sent as keys won't be seen; the rest still works.", hidOpen))
}

// MARK: - Run

check(AudioOutputUnitStart(unit), "start audio")
log("listening for \(Int(seconds)) s. Talk, press mute, wait 5 s, press it again. Repeat 3 times.")

func dbfs(_ x: Float) -> String { x > 0 ? String(format: "%6.1f dBFS", 20 * log10(x)) : "  -inf dBFS" }

var allRuns: [(start: Date, frames: Int)] = []
var windowZeroFrac: [Double] = []

let ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    os_unfair_lock_lock(stats.lock)
    let peak = stats.peak, samples = stats.samples, zeros = stats.zeroSamples
    let runs = stats.finishedRuns, current = stats.zeroRun, callbacks = stats.callbacks
    stats.peak = 0; stats.samples = 0; stats.zeroSamples = 0; stats.finishedRuns = []; stats.callbacks = 0
    os_unfair_lock_unlock(stats.lock)

    for r in runs {
        allRuns.append(r)
        log(String(format: "EVENT zero run ended: %.0f ms of exact zeros", Double(r.frames) / sampleRate * 1000))
    }
    let pct = samples > 0 ? Double(zeros) / Double(samples) * 100 : 0
    windowZeroFrac.append(pct)
    let running = current > 0 ? String(format: "  zero run so far %.0f ms", Double(current) / sampleRate * 1000) : ""
    if callbacks == 0 {
        log("no audio arrived in the last 0.5 s (device stopped sending)")
    } else {
        log("peak \(dbfs(peak))  zeros \(String(format: "%5.1f", pct))%\(running)")
    }
}

RunLoop.main.run(until: Date().addingTimeInterval(seconds))
ticker.invalidate()
AudioOutputUnitStop(unit)

os_unfair_lock_lock(stats.lock)
if stats.zeroRun >= Int(sampleRate * minRunMs / 1000) {
    allRuns.append((stats.runStart ?? Date(), stats.zeroRun))
}
os_unfair_lock_unlock(stats.lock)

// MARK: - Summary

log("---- summary ----")
log("zero runs of \(Int(minRunMs)) ms or more: \(allRuns.count)")
for r in allRuns {
    log(String(format: "  at %.1f s: %.0f ms", r.start.timeIntervalSince(startTime), Double(r.frames) / sampleRate * 1000))
}
log("CoreAudio property changes: \(propertyEvents)")
log("HID button events from \(picked.name): \(hidContext.events)")
log("log saved to \(logPath)")
