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
        didSet {
            preferences.previewMode = previewMode
            overlay?.update()
        }
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

    // MARK: Recording and speech

    /// The newest saved row.
    private(set) var lastChunk: ChunkSummary?
    /// Text heard so far in the thought in progress (final plus volatile).
    private(set) var liveText = ""
    /// The text of the thought that just ended, shown briefly in Transcript mode.
    private(set) var justFinishedText: String?
    private(set) var databaseSize: Int64 = 0
    private(set) var dailyBytes: [(day: String, bytes: Int64)] = []
    private(set) var databaseError: String?
    private(set) var speechFiles: SpeechFilesState = .checking

    private var store: ChunkStore?
    private var session: SpeechSession?
    private var thoughtSignalAt = Date()
    private var speechLocale: Locale?
    private var overlay: OverlayController?
    private var thoughtsInFlight = 0

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
        capture.onTrouble = { [weak self] reason in
            self?.log(.warning, "mic", "\(reason). Reopening the mic.")
            self?.controller.restart()
        }

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

        do {
            store = try ChunkStore()
        } catch {
            databaseError = "Can't open the database: \(error)"
        }
        overlay = OverlayController(model: self)
        log(.info, "app", "Started \(Self.appVersion)")
        Task {
            await refreshDatabaseInfo()
            await checkSpeechFiles()
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
        log(.info, "mic", Self.describe(state))
        if !state.isListening {
            level = 0
            if activity == .hearing { activity = .idle }
        }
    }

    private func handle(_ event: ThoughtEvent) {
        switch event {
        case .started(_, let preRoll):
            activity = .hearing
            thoughtSignalAt = Date()
            liveText = ""
            justFinishedText = nil
            session = startSpeech()
            session?.append(preRoll)
        case .audio(let samples):
            // 50 times a second: only feed recognition, nothing else.
            session?.append(samples)
            return
        case .ended(let thought):
            activity = .idle
            save(thought, transcription: session)
            session = nil
        }
        overlay?.update()
    }

    private func startSpeech() -> SpeechSession? {
        guard speechFiles == .installed, let speechLocale, let rate = capture.sampleRate else {
            log(.warning, "speech", "No recognition for this thought: speech files \(speechFiles), "
                + "locale \(speechLocale?.identifier ?? "none"), stream rate \(capture.sampleRate.map { "\($0)" } ?? "none")")
            return nil
        }
        return SpeechSession(locale: speechLocale, sampleRate: rate) { [weak self] text in
            Task { @MainActor in
                guard let self, self.activity == .hearing else { return }
                self.liveText = text
                self.overlay?.update()
            }
        }
    }

    /// Saves the audio first, then the text when recognition finishes.
    private func save(_ thought: CapturedThought, transcription: SpeechSession?) {
        guard let store else { return }
        let device: AudioDeviceInfo? = if case .listening(let info) = micState { info } else { nil }
        let target = NSWorkspace.shared.frontmostApplication
        let isUs = target?.bundleIdentifier == Bundle.main.bundleIdentifier
        let meta = ChunkMeta(
            thought: thought, signalAt: thoughtSignalAt,
            micUID: device?.uid ?? pinnedUID ?? "unknown", micName: device?.name ?? pinnedName,
            micModelUID: device?.modelUID,
            targetAppBundleID: isUs ? nil : target?.bundleIdentifier,
            targetAppName: isUs ? nil : target?.localizedName,
            appVersion: Self.appVersion)
        let recorder = ChunkRecorder(store: store)
        let transcription: (any ThoughtTranscription)? = transcription
            ?? UnavailableTranscription(reason: speechFiles == .installed
                ? "Speech recognition didn't start for this thought."
                : SpeechSetupError.assetsMissing.description)
        thoughtsInFlight += 1
        Task.detached(priority: .userInitiated) { [weak self] in
            await recorder.record(thought, meta: meta, transcription: transcription, saved: { _ in
                Task { @MainActor in await self?.refreshDatabaseInfo() }
            })
            await MainActor.run { self?.thoughtsInFlight -= 1 }
            await self?.refreshDatabaseInfo()
            await self?.showFinished()
        }
    }

    private func showFinished() {
        guard activity != .hearing else { return }
        justFinishedText = lastChunk?.rawText
        overlay?.update()
        Task {
            try? await Task.sleep(for: .seconds(4))
            if self.activity != .hearing {
                self.justFinishedText = nil
                self.overlay?.update()
            }
        }
    }

    func refreshDatabaseInfo() async {
        guard let store else { return }
        lastChunk = try? await store.latest()
        databaseSize = store.sizeOnDisk()
        dailyBytes = (try? await store.dailyBytes(days: 7)) ?? []
    }

    func deleteAllRecordings() async {
        guard let store else { return }
        do {
            try await store.deleteAllRecordings()
        } catch {
            databaseError = "Couldn't delete: \(error)"
        }
        await refreshDatabaseInfo()
    }

    var databasePath: String { store?.path ?? Schema.defaultPath }

    /// Adds a line to the database's `events` table.
    func log(_ level: LogLevel, _ category: String, _ message: String) {
        guard let store else { return }
        Task { await store.log(level, category, message) }
    }

    private static func describe(_ state: MicState) -> String {
        switch state {
        case .off: "Mic closed (switched off)"
        case .noMicPicked: "No mic picked"
        case .noPermission: "No microphone permission"
        case .missing(let uid): "Mic missing: \(uid)"
        case .listening(let device): "Listening to \(device.name) (\(device.uid), \(Int(device.sampleRate)) Hz)"
        case .failed(let message): "Mic failed: \(message)"
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    // MARK: Speech files

    func checkSpeechFiles() async {
        speechLocale = await SpeechAssets.locale()
        guard speechLocale != nil else {
            speechFiles = .failed("English speech recognition isn't available on this Mac.")
            return
        }
        if case .downloading = speechFiles { return }
        speechFiles = await SpeechAssets.isInstalled() ? .installed : .missing
        permissions.speechReady = speechFiles == .installed
        log(.info, "speech", "English speech files (\(speechLocale?.identifier ?? "?")): \(speechFiles)")
        if speechFiles == .installed, let store, let speechLocale {
            let recorder = ChunkRecorder(store: store)
            Task.detached(priority: .utility) { [weak self] in
                await recorder.finishPending(locale: speechLocale)
                await self?.refreshDatabaseInfo()
            }
        }
    }

    func installSpeechFiles() {
        if case .downloading = speechFiles { return }
        speechFiles = .downloading(0)
        Task {
            do {
                try await SpeechAssets.install { fraction in
                    Task { @MainActor in
                        if case .downloading = self.speechFiles { self.speechFiles = .downloading(fraction) }
                    }
                }
                speechFiles = .checking
                await checkSpeechFiles()
            } catch {
                speechFiles = .failed("The download failed: \(error.localizedDescription)")
                log(.error, "speech", "Speech file download failed: \(error)")
            }
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

/// Stands in for recognition that couldn't run, so the row says why.
struct UnavailableTranscription: ThoughtTranscription {
    let reason: String
    var recognizer: String { "none" }
    func finish(through seconds: Double) async throws -> String {
        throw DatabaseError(message: reason)
    }
}

enum SpeechFilesState: Equatable {
    case checking
    case missing
    case downloading(Double)
    case installed
    case failed(String)
}
