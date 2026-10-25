import CoreAudio

/// What the mic side of the app is doing.
public enum MicState: Equatable, Sendable {
    case off
    case noMicPicked
    case noPermission
    /// The pinned mic isn't connected. The app waits for this exact UID.
    case missing(uid: String)
    case listening(AudioDeviceInfo)
    case failed(String)

    public var isListening: Bool {
        if case .listening = self { return true }
        return false
    }
}

/// Keeps the audio stream open on the pinned mic and nothing else.
///
/// Rules: only the saved device UID is ever opened. When it disappears the
/// state becomes `.missing` and the stream closes; when the same UID comes
/// back, listening resumes. The pinned UID only changes through `pick(_:)`.
@MainActor
public final class DeviceController {
    public private(set) var state: MicState = .off
    public private(set) var devices: [AudioDeviceInfo] = []
    public private(set) var pinnedUID: String?

    public var onStateChange: ((MicState) -> Void)?
    /// Called when the list of input devices changes.
    public var onDevicesChange: (([AudioDeviceInfo]) -> Void)?
    /// Called only when the person picks a mic, so it can be saved.
    public var onPick: ((String) -> Void)?

    private let source: AudioDeviceSource
    private let stream: CaptureStream
    private let hasPermission: () -> Bool
    private var isOn: Bool

    public init(source: AudioDeviceSource, stream: CaptureStream, pinnedUID: String?, isOn: Bool,
                hasPermission: @escaping () -> Bool) {
        self.source = source
        self.stream = stream
        self.pinnedUID = pinnedUID
        self.isOn = isOn
        self.hasPermission = hasPermission
        source.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    public func setOn(_ on: Bool) {
        isOn = on
        refresh()
    }

    /// The person picked a mic. Switches right away.
    public func pick(_ uid: String) {
        guard uid != pinnedUID else { return }
        if stream.runningDeviceID != nil {
            stream.stop(reason: .micChanged)
        }
        pinnedUID = uid
        onPick?(uid)
        refresh()
    }

    /// Closes and reopens the stream, for example after the device's
    /// sample rate changed or audio stopped arriving.
    public func restart() {
        if stream.runningDeviceID != nil {
            stream.stop(reason: .micLost)
        }
        refresh()
    }

    /// Re-reads the device list and opens or closes the stream to match.
    public func refresh() {
        let list = source.inputDevices()
        let changed = list != devices
        devices = list
        set(evaluate())
        if changed { onDevicesChange?(list) }
    }

    private func evaluate() -> MicState {
        guard isOn else { return close(.off, reason: .switchedOff) }
        guard let uid = pinnedUID else { return close(.noMicPicked, reason: .micLost) }
        guard hasPermission() else { return close(.noPermission, reason: .micLost) }
        guard let info = devices.first(where: { $0.uid == uid }), info.isAlive,
              let id = source.deviceID(forUID: uid), id == info.id
        else {
            return close(.missing(uid: uid), reason: .micLost)
        }

        if stream.runningDeviceID == id {
            return .listening(info)
        }
        if stream.runningDeviceID != nil {
            stream.stop(reason: .micLost)
        }
        do {
            try stream.start(device: info)
            return .listening(info)
        } catch {
            return .failed("Couldn't open \(info.name): \(error)")
        }
    }

    private func close(_ state: MicState, reason: ThoughtEndReason) -> MicState {
        if stream.runningDeviceID != nil {
            stream.stop(reason: reason)
        }
        return state
    }

    private func set(_ newState: MicState) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }
}
