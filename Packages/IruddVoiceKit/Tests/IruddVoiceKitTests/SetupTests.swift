import Testing
@testable import IruddVoiceKit

struct SetupTests {
    @Test func nothingAskedYet() {
        let checklist = SetupChecklist(permissions: [:])
        #expect(checklist.missingRequired == [.microphone, .speechRecognition, .accessibility, .clipboard])
        #expect(!checklist.canFinish)
    }

    @Test func everythingGrantedCanFinish() {
        let checklist = SetupChecklist(permissions: [
            .microphone: .granted, .speechRecognition: .granted, .accessibility: .granted, .clipboard: .granted,
        ], micPicked: true, speechReady: true)
        #expect(checklist.canFinish)
    }

    @Test func clipboardIsNeededToPaste() {
        let checklist = SetupChecklist(permissions: [
            .microphone: .granted, .speechRecognition: .granted, .accessibility: .granted, .clipboard: .denied,
        ], micPicked: true, speechReady: true)
        #expect(checklist.missingRequired == [.clipboard])
        #expect(!checklist.canFinish)
    }

    @Test func speechFilesMustBeInstalled() {
        let checklist = SetupChecklist(permissions: [
            .microphone: .granted, .speechRecognition: .granted, .accessibility: .granted, .clipboard: .granted,
        ], micPicked: true, speechReady: false)
        #expect(!checklist.canFinish)
    }

    @Test func aMicMustBePicked() {
        let checklist = SetupChecklist(permissions: [
            .microphone: .granted, .speechRecognition: .granted, .accessibility: .granted, .clipboard: .granted,
        ], micPicked: false)
        #expect(checklist.missingRequired.isEmpty)
        #expect(!checklist.canFinish)
    }

    @Test func deniedRequiredPermissionBlocksFinish() {
        let checklist = SetupChecklist(permissions: [
            .microphone: .denied, .speechRecognition: .granted, .accessibility: .granted, .clipboard: .granted,
        ])
        #expect(checklist.missingRequired == [.microphone])
        #expect(!checklist.canFinish)
    }
}
