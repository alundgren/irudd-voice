import AppKit
import IruddVoiceKit
import Observation
import ServiceManagement

/// App-wide state shared by the panel, Settings and setup.
@MainActor
@Observable
final class AppModel {
    let preferences = Preferences(store: UserDefaults.standard)
    let permissions = PermissionChecker()

    /// The main switch. Off closes the mic stream and records nothing.
    var isOn: Bool {
        didSet { preferences.isOn = isOn }
    }

    var previewMode: PreviewMode {
        didSet { preferences.previewMode = previewMode }
    }

    private(set) var hasCompletedSetup: Bool

    /// Whether the pinned mic is connected. Set by mic capture (next work item).
    var micConnected = true

    var activity: AppStatus.Activity = .idle

    var status: AppStatus {
        AppStatus.resolve(isOn: isOn, micConnected: micConnected, activity: activity)
    }

    private(set) var startAtLogin: SMAppService.Status = SMAppService.mainApp.status
    var loginItemError: String?

    init() {
        isOn = preferences.isOn
        previewMode = preferences.previewMode
        hasCompletedSetup = preferences.hasCompletedSetup
    }

    func refreshLoginItem() {
        startAtLogin = SMAppService.mainApp.status
    }

    func setStartAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshLoginItem()
    }

    func finishSetup() {
        preferences.hasCompletedSetup = true
        hasCompletedSetup = true
    }
}
