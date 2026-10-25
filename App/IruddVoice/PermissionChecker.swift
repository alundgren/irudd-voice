import AppKit
import ApplicationServices
import AVFoundation
import IruddVoiceKit
import Observation
import Speech

/// Reads and requests the permissions first-run setup needs.
@MainActor
@Observable
final class PermissionChecker {
    private(set) var checklist = SetupChecklist(permissions: [:])

    /// Set by the app model when a mic is picked.
    var micPicked = false {
        didSet { refresh() }
    }

    init() {
        refresh()
    }

    func refresh() {
        let next = SetupChecklist(permissions: [
            .microphone: microphone(),
            .speechRecognition: speech(),
            .accessibility: AXIsProcessTrusted() ? .granted : .notAsked,
            .clipboard: clipboard(),
        ], micPicked: micPicked)
        if next != checklist { checklist = next }
    }

    func request(_ permission: Permission) {
        switch permission {
        case .microphone:
            if checklist.state(of: .microphone) == .denied {
                openPrivacySettings("Privacy_Microphone")
            } else {
                // These callbacks arrive on a background queue. Marking them
                // @Sendable keeps Swift from treating them as main-actor code,
                // which crashes the app when macOS calls them.
                AVCaptureDevice.requestAccess(for: .audio) { @Sendable _ in
                    Task { @MainActor in self.refresh() }
                }
            }
        case .speechRecognition:
            if checklist.state(of: .speechRecognition) == .denied {
                openPrivacySettings("Privacy_SpeechRecognition")
            } else {
                SFSpeechRecognizer.requestAuthorization { @Sendable _ in
                    Task { @MainActor in self.refresh() }
                }
            }
        case .accessibility:
            // Adds the app to the Accessibility list. The person turns it on there.
            // The key is kAXTrustedCheckOptionPrompt; Swift 6 rejects that global
            // as shared mutable state, so its string value is used directly.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            openPrivacySettings("Privacy_Accessibility")
        case .clipboard:
            // The first programmatic read shows macOS's clipboard alert and adds
            // the app to System Settings, where "Always allow" can be chosen.
            _ = NSPasteboard.general.string(forType: .string)
            openPrivacySettings("Privacy_Pasteboard")
        }
        refresh()
    }

    private func microphone() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notAsked
        }
    }

    private func speech() -> PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notAsked
        }
    }

    private func clipboard() -> PermissionState {
        switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow: .granted
        case .alwaysDeny: .denied
        default: .notAsked
        }
    }

    private func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
