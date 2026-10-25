import AppKit
import AVFoundation
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
        didSet {
            preferences.isOn = isOn
            updateListening()
        }
    }

    var previewMode: PreviewMode {
        didSet { preferences.previewMode = previewMode }
    }

    private(set) var hasCompletedSetup: Bool

    // MARK: Mic

    private(set) var micState: MicState = .off
    private(set) var devices: [AudioDeviceInfo] = []
    private(set) var pinnedUID: String?
    private(set) var pinnedName: String?
    /// Peak level of the pinned mic over the last 100 ms (0…1).
    private(set) var level: Float = 0

    private(set) var activity: AppStatus.Activity = .idle
    private(set) var lastThought: ThoughtSummary?

    // MARK: Hotkey

    private(set) var hotkey: Hotkey?
    private(set) var hotkeyError: String?

    var status: AppStatus {
        let ready = hasCompletedSetup && micState != .noMicPicked && micState != .noPermission
        return AppStatus.resolve(isSetUp: ready, isOn: isOn, micConnected: micConnected, activity: activity)
    }

    private var micConnected: Bool {
        switch micState {
        case .missing, .failed: false
        default: true
        }
    }

    private(set) var startAtLogin: SMAppService.Status = SMAppService.mainApp.status
    var loginItemError: String?

    private let capture = LiveCapture()
    private let deviceSource = CoreAudioDevices()
    private var controller: DeviceController!
    private let hotkeys = HotkeyCenter()

    init() {
        isOn = preferences.isOn
        previewMode = preferences.previewMode
        hasCompletedSetup = preferences.hasCompletedSetup
        pinnedUID = preferences.pinnedMicUID
        pinnedName = preferences.pinnedMicName
        hotkey = preferences.hotkey
        permissions.micPicked = pinnedUID != nil

        capture.onEvent = { [weak self] event in self?.handle(event) }
        capture.onLevel = { [weak self] peak in self?.level = peak }
        capture.onTrouble = { [weak self] _ in self?.controller.restart() }

        controller = DeviceController(
            source: deviceSource, stream: capture, pinnedUID: pinnedUID,
            isOn: isOn && hasCompletedSetup,
            hasPermission: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized })
        controller.onStateChange = { [weak self] state in self?.micStateChanged(state) }
        controller.onPick = { [weak self] uid in self?.preferences.pinnedMicUID = uid }
        controller.onDevicesChange = { [weak self] list in self?.devices = list }
        devices = controller.devices
        micStateChanged(controller.state)

        hotkeys.onPress = { [weak self] in self?.capture.hotkey() }
        if !hotkeys.register(hotkey) {
            hotkeyError = "\(hotkey?.display ?? "The hotkey") is already used by another app."
        }
    }

    // MARK: Mic

    /// Mics to show: every input device, plus the pinned one if it's unplugged.
    var micChoices: [MicChoice] {
        var choices = devices.map { MicChoice(uid: $0.uid, name: $0.name, connected: true) }
        if let pinnedUID, !devices.contains(where: { $0.uid == pinnedUID }) {
            choices.insert(MicChoice(uid: pinnedUID, name: pinnedName ?? "Unknown mic", connected: false), at: 0)
        }
        return choices
    }

    /// The person picked a mic. Never called automatically.
    func pickMic(_ uid: String) {
        pinnedName = devices.first { $0.uid == uid }?.name ?? pinnedName
        preferences.pinnedMicName = pinnedName
        pinnedUID = uid
        controller.pick(uid)
        permissions.micPicked = true
    }

    /// Re-reads permissions and devices, for example while setup is open.
    func refresh() {
        permissions.refresh()
        controller.refresh()
    }

    private func updateListening() {
        controller.setOn(isOn && hasCompletedSetup)
    }

    private func micStateChanged(_ state: MicState) {
        micState = state
        if !state.isListening {
            level = 0
            if activity == .hearing { activity = .idle }
        }
    }

    private func handle(_ event: ThoughtEvent) {
        switch event {
        case .started:
            activity = .hearing
        case .ended(let thought):
            activity = .idle
            lastThought = ThoughtSummary(thought: thought, endedAt: Date())
        }
    }

    // MARK: Hotkey

    func setHotkey(_ newHotkey: Hotkey?) {
        hotkeyError = nil
        if hotkeys.register(newHotkey) {
            hotkey = newHotkey
            preferences.hotkey = newHotkey
        } else {
            hotkeyError = "\(newHotkey?.display ?? "That shortcut") is already used by another app."
            hotkeys.register(hotkey)
        }
    }

    /// Turns the hotkey off while a new one is being recorded, so pressing
    /// the old one doesn't start a thought.
    func pauseHotkey() {
        hotkeys.unregister()
    }

    func resumeHotkey() {
        hotkeys.register(hotkey)
    }

    // MARK: Login item and setup

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
        updateListening()
    }
}

struct MicChoice: Identifiable, Equatable {
    let uid: String
    let name: String
    let connected: Bool
    var id: String { uid }
}

/// What the panel shows about the last thought until recording is built.
struct ThoughtSummary {
    let duration: Double
    let startReason: ThoughtStartReason
    let endReason: ThoughtEndReason
    let endedAt: Date

    init(thought: CapturedThought, endedAt: Date) {
        duration = thought.duration
        startReason = thought.startReason
        endReason = thought.endReason
        self.endedAt = endedAt
    }
}
