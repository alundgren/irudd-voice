import Testing
@testable import IruddVoiceKit

struct AppStatusTests {
    @Test func unfinishedSetupWinsOverEverything() {
        #expect(AppStatus.resolve(isSetUp: false, isOn: true, micConnected: true, activity: .idle) == .notSetUp)
        #expect(AppStatus.resolve(isSetUp: false, isOn: false, micConnected: false, activity: .hearing) == .notSetUp)
    }

    @Test func offWinsOverMicAndActivity() {
        #expect(AppStatus.resolve(isSetUp: true, isOn: false, micConnected: false, activity: .hearing) == .off)
        #expect(AppStatus.resolve(isSetUp: true, isOn: false, micConnected: true, activity: .textWaiting) == .off)
    }

    @Test func missingMicWinsOverActivity() {
        #expect(AppStatus.resolve(isSetUp: true, isOn: true, micConnected: false, activity: .hearing) == .micMissing)
        #expect(AppStatus.resolve(isSetUp: true, isOn: true, micConnected: false, activity: .idle) == .micMissing)
    }

    @Test func activityWhenOnWithMic() {
        #expect(AppStatus.resolve(isSetUp: true, isOn: true, micConnected: true, activity: .idle) == .ready)
        #expect(AppStatus.resolve(isSetUp: true, isOn: true, micConnected: true, activity: .hearing) == .hearing)
        #expect(AppStatus.resolve(isSetUp: true, isOn: true, micConnected: true, activity: .cleaningUp) == .cleaningUp)
        #expect(AppStatus.resolve(isSetUp: true, isOn: true, micConnected: true, activity: .textWaiting) == .textWaiting)
    }

    @Test func everyStatusHasTextAndIcon() {
        for status in AppStatus.allCases {
            #expect(!status.title.isEmpty)
            #expect(!status.detail.isEmpty)
            #expect(!status.symbolName.isEmpty)
        }
    }
}
