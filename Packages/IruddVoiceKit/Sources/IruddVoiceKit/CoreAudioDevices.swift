import CoreAudio
import Foundation

/// Lists input devices through CoreAudio and reports changes: devices
/// plugged in or out, and devices that stop working.
@MainActor
public final class CoreAudioDevices: AudioDeviceSource {
    public var onChange: (@MainActor () -> Void)?

    private var watchedAlive: Set<AudioDeviceID> = []

    public init() {
        var address = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    public func inputDevices() -> [AudioDeviceInfo] {
        let list = Self.allDeviceIDs().compactMap(Self.info)
        for device in list where !watchedAlive.contains(device.id) {
            watchedAlive.insert(device.id)
            var address = Self.address(kAudioDevicePropertyDeviceIsAlive)
            AudioObjectAddPropertyListenerBlock(device.id, &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
        }
        return list
    }

    /// Looks the UID up with kAudioHardwarePropertyTranslateUIDToDevice, so
    /// the number always belongs to that exact device.
    public func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = Self.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
        }
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    // MARK: - CoreAudio reads

    nonisolated static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    nonisolated static func info(_ id: AudioDeviceID) -> AudioDeviceInfo? {
        let channels = inputChannelCount(id)
        guard channels > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioDeviceInfo(
            id: id,
            uid: uid,
            name: string(id, kAudioObjectPropertyName) ?? uid,
            modelUID: string(id, kAudioDevicePropertyModelUID) ?? "",
            inputChannels: channels,
            sampleRate: value(id, kAudioDevicePropertyNominalSampleRate, Float64(0)) ?? 0,
            isAlive: (value(id, kAudioDevicePropertyDeviceIsAlive, UInt32(0)) ?? 0) != 0
        )
    }

    nonisolated static func value<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                                      _ initial: T) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr ? result : nil
    }

    nonisolated static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result) == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }

    nonisolated static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
