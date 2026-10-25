import CoreAudio

/// An audio input device as macOS reports it.
public struct AudioDeviceInfo: Sendable, Equatable, Identifiable {
    /// CoreAudio's number for the device. Changes when it's plugged in again.
    public let id: AudioDeviceID
    /// Stable ID for this exact device. The only thing a mic is pinned by.
    public let uid: String
    public let name: String
    /// Same for every unit of the same model. Only for diagnostics.
    public let modelUID: String
    public let inputChannels: Int
    public let sampleRate: Double
    public let isAlive: Bool

    public init(id: AudioDeviceID, uid: String, name: String, modelUID: String,
                inputChannels: Int, sampleRate: Double, isAlive: Bool) {
        self.id = id
        self.uid = uid
        self.name = name
        self.modelUID = modelUID
        self.inputChannels = inputChannels
        self.sampleRate = sampleRate
        self.isAlive = isAlive
    }
}

/// Lists input devices and says when the list changes.
@MainActor
public protocol AudioDeviceSource: AnyObject {
    func inputDevices() -> [AudioDeviceInfo]
    /// CoreAudio's current number for this exact UID, or nil if it isn't connected.
    func deviceID(forUID uid: String) -> AudioDeviceID?
    var onChange: (@MainActor () -> Void)? { get set }
}

/// An open audio stream from one device.
@MainActor
public protocol CaptureStream: AnyObject {
    func start(device: AudioDeviceInfo) throws
    /// Closes the stream. `reason` ends a thought in progress.
    func stop(reason: ThoughtEndReason)
    var runningDeviceID: AudioDeviceID? { get }
}
