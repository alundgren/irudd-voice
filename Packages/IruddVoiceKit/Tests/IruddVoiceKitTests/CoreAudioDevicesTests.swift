import CoreAudio
import Foundation
import Testing
@testable import IruddVoiceKit

@MainActor
struct CoreAudioDevicesTests {
    @Test(arguments: [false, true])
    func disconnectReturnsBeforeClosingTheStream(fromBackgroundQueue: Bool) async {
        let boya = mic(85, uid: "BOYA-1", name: "BY-GM18CU")
        let builtIn = mic(80, uid: "BuiltInMicrophoneDevice")
        let source = FakeDevices()
        source.devices = [boya, builtIn]
        let stream = FakeStream()
        let controller = DeviceController(source: source, stream: stream, pinnedUID: boya.uid,
                                          isOn: true, hasPermission: { true })
        let queue = DispatchQueue(label: "test.core-audio-notification")

        await withCheckedContinuation { continuation in
            let listener = CoreAudioDevices.makeChangeListener {
                // Model teardown waiting for its notification queue. This
                // must be free before closing the stream on the main actor.
                queue.sync {}
                controller.refresh()
                continuation.resume()
            }
            source.devices = [builtIn]
            let notify = {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDevices,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                listener(1, &address)
            }
            if fromBackgroundQueue {
                queue.sync(execute: notify)
            } else {
                notify()
            }
            #expect(controller.state == .listening(boya))
            #expect(stream.stopReasons.isEmpty)
        }

        #expect(controller.state == .missing(uid: boya.uid))
        #expect(stream.stopReasons == [.micLost])
        #expect(stream.runningDeviceID == nil)
        #expect(stream.opened == [boya.id])

        let reconnected = mic(97, uid: boya.uid, name: boya.name)
        await withCheckedContinuation { continuation in
            let listener = CoreAudioDevices.makeChangeListener {
                controller.refresh()
                continuation.resume()
            }
            source.devices = [builtIn, reconnected]
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            listener(1, &address)
            #expect(controller.state == .missing(uid: boya.uid))
        }
        #expect(controller.state == .listening(reconnected))
        #expect(stream.opened == [boya.id, reconnected.id])
        #expect(controller.pinnedUID == boya.uid)
    }
}
