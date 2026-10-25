import CoreAudio
import Testing
@testable import IruddVoiceKit

@MainActor
final class FakeDevices: AudioDeviceSource {
    var devices: [AudioDeviceInfo] = []
    var onChange: (@MainActor () -> Void)?

    func inputDevices() -> [AudioDeviceInfo] { devices }
    func deviceID(forUID uid: String) -> AudioDeviceID? {
        devices.first { $0.uid == uid }?.id
    }

    func set(_ list: [AudioDeviceInfo]) {
        devices = list
        onChange?()
    }
}

@MainActor
final class FakeStream: CaptureStream {
    private(set) var runningDeviceID: AudioDeviceID?
    private(set) var opened: [AudioDeviceID] = []
    private(set) var stopReasons: [ThoughtEndReason] = []
    var failNextStart = false

    func start(device: AudioDeviceInfo) throws {
        if failNextStart {
            failNextStart = false
            throw CaptureError.cannotOpen("test")
        }
        opened.append(device.id)
        runningDeviceID = device.id
    }

    func stop(reason: ThoughtEndReason) {
        stopReasons.append(reason)
        runningDeviceID = nil
    }
}

func mic(_ id: AudioDeviceID, uid: String, name: String = "Mic", model: String = "M:1:1", alive: Bool = true)
    -> AudioDeviceInfo
{
    AudioDeviceInfo(id: id, uid: uid, name: name, modelUID: model, inputChannels: 1, sampleRate: 48000, isAlive: alive)
}

@MainActor
struct DeviceControllerTests {
    let boya = mic(85, uid: "BOYA-1", name: "BY-GM18CU", model: "BY-GM18CU:0002:0005")
    let builtIn = mic(80, uid: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone")
    let airpods = mic(90, uid: "AIRPODS", name: "AirPods")

    func make(pinned: String?, devices: [AudioDeviceInfo], on: Bool = true, permission: Bool = true)
        -> (DeviceController, FakeDevices, FakeStream)
    {
        let source = FakeDevices()
        source.devices = devices
        let stream = FakeStream()
        let controller = DeviceController(source: source, stream: stream, pinnedUID: pinned, isOn: on,
                                          hasPermission: { permission })
        return (controller, source, stream)
    }

    @Test func opensOnlyThePinnedMic() {
        let (controller, _, stream) = make(pinned: "BOYA-1", devices: [builtIn, boya, airpods])
        #expect(controller.state == .listening(boya))
        #expect(stream.opened == [85])
    }

    @Test func unplugMeansMissingAndNoOtherMic() {
        let (controller, source, stream) = make(pinned: "BOYA-1", devices: [builtIn, boya])
        source.set([builtIn, airpods])
        #expect(controller.state == .missing(uid: "BOYA-1"))
        #expect(stream.runningDeviceID == nil)
        #expect(stream.stopReasons == [.micLost])
        #expect(stream.opened == [85])
        #expect(controller.pinnedUID == "BOYA-1")
    }

    @Test func sameUIDComingBackResumesEvenWithANewDeviceNumber() {
        let (controller, source, stream) = make(pinned: "BOYA-1", devices: [builtIn, boya])
        source.set([builtIn])
        let replugged = mic(97, uid: "BOYA-1", name: "BY-GM18CU", model: "BY-GM18CU:0002:0005")
        source.set([builtIn, replugged])
        #expect(controller.state == .listening(replugged))
        #expect(stream.opened == [85, 97])
    }

    @Test func otherDevicesNeverReplaceAMissingMic() {
        let (controller, source, stream) = make(pinned: "BOYA-1", devices: [builtIn, boya])
        source.set([builtIn])
        // Same model, different unit.
        source.set([builtIn, mic(98, uid: "BOYA-2", name: "BY-GM18CU", model: "BY-GM18CU:0002:0005")])
        // A new, unknown device.
        source.set([builtIn, airpods, mic(99, uid: "NEW", name: "USB Audio")])
        #expect(controller.state == .missing(uid: "BOYA-1"))
        #expect(stream.opened == [85])
        #expect(controller.pinnedUID == "BOYA-1")
    }

    @Test func deadDeviceCountsAsMissing() {
        let (controller, source, _) = make(pinned: "BOYA-1", devices: [builtIn, boya])
        source.set([builtIn, mic(85, uid: "BOYA-1", alive: false)])
        #expect(controller.state == .missing(uid: "BOYA-1"))
    }

    @Test func pickingSwitchesAndSaves() {
        let (controller, _, stream) = make(pinned: "BOYA-1", devices: [builtIn, boya])
        var saved: [String] = []
        controller.onPick = { saved.append($0) }
        controller.pick("BuiltInMicrophoneDevice")
        #expect(controller.state == .listening(builtIn))
        #expect(stream.stopReasons == [.micChanged])
        #expect(stream.opened == [85, 80])
        #expect(saved == ["BuiltInMicrophoneDevice"])
        #expect(controller.devices.contains(boya))
    }

    @Test func pickingAMissingMicWaitsForIt() {
        let (controller, _, stream) = make(pinned: "BOYA-1", devices: [builtIn, boya])
        controller.pick("GONE")
        #expect(controller.state == .missing(uid: "GONE"))
        #expect(stream.runningDeviceID == nil)
    }

    @Test func offClosesTheStream() {
        let (controller, _, stream) = make(pinned: "BOYA-1", devices: [boya])
        controller.setOn(false)
        #expect(controller.state == .off)
        #expect(stream.runningDeviceID == nil)
        #expect(stream.stopReasons == [.switchedOff])
        controller.setOn(true)
        #expect(controller.state == .listening(boya))
    }

    @Test func nothingOpensWithoutAPickOrPermission() {
        let (noPick, _, s1) = make(pinned: nil, devices: [builtIn, boya])
        #expect(noPick.state == .noMicPicked)
        #expect(s1.opened.isEmpty)
        let (noPermission, _, s2) = make(pinned: "BOYA-1", devices: [boya], permission: false)
        #expect(noPermission.state == .noPermission)
        #expect(s2.opened.isEmpty)
    }

    @Test func aFailedOpenIsReportedAndRetried() {
        let source = FakeDevices()
        source.devices = [boya]
        let stream = FakeStream()
        stream.failNextStart = true
        let controller = DeviceController(source: source, stream: stream, pinnedUID: "BOYA-1", isOn: true,
                                          hasPermission: { true })
        guard case .failed = controller.state else {
            Issue.record("expected failed, got \(controller.state)")
            return
        }
        controller.refresh()
        #expect(controller.state == .listening(boya))
    }

    @Test func reportsNewDevicesWithoutChangingTheMic() {
        let (controller, source, stream) = make(pinned: "BOYA-1", devices: [boya])
        var lists: [[AudioDeviceInfo]] = []
        controller.onDevicesChange = { lists.append($0) }
        source.set([boya, airpods])
        #expect(lists == [[boya, airpods]])
        #expect(controller.state == .listening(boya))
        #expect(stream.opened == [85])
    }

    @Test func restartReopensTheSameMic() {
        let (controller, _, stream) = make(pinned: "BOYA-1", devices: [boya])
        controller.restart()
        #expect(stream.opened == [85, 85])
        #expect(controller.state == .listening(boya))
    }
}
