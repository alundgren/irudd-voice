import Testing
@testable import IruddVoiceKit

struct SetupTests {
    @Test func nothingAskedYet() {
        let checklist = SetupChecklist(permissions: [:])
        #expect(checklist.missingRequired == [.microphone, .speechRecognition, .accessibility])
        #expect(!checklist.canFinish)
    }

    @Test func clipboardIsOptional() {
        let checklist = SetupChecklist(permissions: [
            .microphone: .granted, .speechRecognition: .granted, .accessibility: .granted, .clipboard: .denied,
        ])
        #expect(checklist.canFinish)
    }

    @Test func deniedRequiredPermissionBlocksFinish() {
        let checklist = SetupChecklist(permissions: [
            .microphone: .denied, .speechRecognition: .granted, .accessibility: .granted,
        ])
        #expect(checklist.missingRequired == [.microphone])
        #expect(!checklist.canFinish)
    }
}
