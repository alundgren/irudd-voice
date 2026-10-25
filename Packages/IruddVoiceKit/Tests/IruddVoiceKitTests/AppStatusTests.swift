import Testing
@testable import IruddVoiceKit

struct AppStatusTests {
    @Test func offWinsOverEverything() {
        #expect(AppStatus.resolve(isOn: false, micConnected: false, activity: .hearing) == .off)
        #expect(AppStatus.resolve(isOn: false, micConnected: true, activity: .textWaiting) == .off)
    }

    @Test func missingMicWinsOverActivity() {
        #expect(AppStatus.resolve(isOn: true, micConnected: false, activity: .hearing) == .micMissing)
        #expect(AppStatus.resolve(isOn: true, micConnected: false, activity: .idle) == .micMissing)
    }

    @Test func activityWhenOnWithMic() {
        #expect(AppStatus.resolve(isOn: true, micConnected: true, activity: .idle) == .ready)
        #expect(AppStatus.resolve(isOn: true, micConnected: true, activity: .hearing) == .hearing)
        #expect(AppStatus.resolve(isOn: true, micConnected: true, activity: .cleaningUp) == .cleaningUp)
        #expect(AppStatus.resolve(isOn: true, micConnected: true, activity: .textWaiting) == .textWaiting)
    }

    @Test func everyStatusHasTextAndIcon() {
        for status in AppStatus.allCases {
            #expect(!status.title.isEmpty)
            #expect(!status.detail.isEmpty)
            #expect(!status.symbolName.isEmpty)
        }
    }
}
