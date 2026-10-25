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
    /// The thought that just ended, shown briefly in Transcript mode: what
    /// was heard, then also what was pasted.
    private(set) var finished: FinishedThought?
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
    private var previewToken = 0

    // MARK: Cleanup

    private var cleanup: CleanupCoordinator?
    private let cleanupClient = CleanupClient()
    private(set) var cleanupSnapshot: CleanupCoordinator.Snapshot?
    private(set) var modelOverview: ModelOverview?
    /// The text last pasted (or held) for a row, for Paste last again.
    private var lastDelivered: (id: Int64, text: String)?

    // MARK: Hotkeys and pasting

    private(set) var hotkeys: [HotkeyAction: Hotkey] = [:]
    private(set) var hotkeyErrors: [HotkeyAction: String] = [:]
    /// Text that couldn't be pasted where it was meant to go.
    private(set) var waiting: WaitingText?
    private let paster = Paster(clipboard: SystemClipboard(), keyboard: SystemKeyboard(), focus: AccessibilityFocus())
    private let focus = AccessibilityFocus()
    /// Throw away was pressed while the thought's text was being made
    /// (recognised and cleaned): don't paste it.
    private var throwAwayPending = false

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

    // MARK: Updates

    private(set) var updateState: UpdateState = .unknown
    let updater = Updater(
        stateDir: (Schema.defaultPath as NSString).deletingLastPathComponent,
        cachesDir: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("irudd-voice").path,
        runner: ProcessRunner())
    var installInfo: InstallInfo? { updater.installInfo() }

    private(set) var startAtLogin: SMAppService.Status = SMAppService.mainApp.status
    var loginItemError: String?

    private let capture = LiveCapture()
    private let deviceSource = CoreAudioDevices()
    private var controller: DeviceController!
    private let hotkeyCenter = HotkeyCenter()

    init() {
        isOn = preferences.isOn
        previewMode = preferences.previewMode
        hasCompletedSetup = preferences.hasCompletedSetup
        pinnedUID = preferences.pinnedMicUID
        pinnedName = preferences.pinnedMicName
        for action in HotkeyAction.allCases {
            hotkeys[action] = preferences.hotkey(for: action)
        }
        permissions.micPicked = pinnedUID != nil

        // Open the database first, so everything after this can log to it.
        do {
            store = try ChunkStore()
        } catch {
            databaseError = "Can't open the database: \(error)"
        }

        if let store {
            if let url = Bundle.main.url(forResource: "cleanup-prompt", withExtension: "json"),
               let prompt = try? CleanupPrompt.load(from: url) {
                let coordinator = CleanupCoordinator(helper: cleanupClient, store: store, prompt: prompt)
                cleanup = coordinator
                cleanupClient.onInterruption = { [weak self] in
                    Task { @MainActor in
                        await coordinator.helperStopped()
                        self?.log(.warning, "cleanup", "The cleanup helper stopped; loading the model again.")
                        await self?.cleanupIdleCheck()
                    }
                }
            } else {
                databaseError = "cleanup-prompt.json is missing from the app, so text is pasted without cleanup."
            }
        }

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

        hotkeyCenter.onPress = { [weak self] action in self?.hotkeyPressed(action) }
        for (action, hotkey) in hotkeys where !hotkeyCenter.register(hotkey, for: action) {
            hotkeyErrors[action] = "\(hotkey.display) is already used by another app."
        }

        overlay = OverlayController(model: self)
        log(.info, "app", "Started \(Self.appVersion)")
        Task {
            await refreshDatabaseInfo()
            await checkSpeechFiles()
        }
        // Load the cleanup model, then check the lease and the active model
        // and write the heartbeat every 10 s (shared/app-state.md). Each
        // check runs on its own, so a slow model load doesn't hold up the
        // heartbeat of the next one.
        Task {
            while true {
                Task { await cleanupIdleCheck() }
                try? await Task.sleep(for: .seconds(10))
            }
        }
        // Check for updates once a little after launch; building waits for Update Now.
        Task {
            try? await Task.sleep(for: .seconds(15))
            if updater.installInfo() != nil { await checkForUpdates() }
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
            showPreview(nil)
            session = startSpeech()
            session?.append(preRoll)
        case .audio(let samples):
            // 50 times a second: only feed recognition, nothing else.
            session?.append(samples)
            return
        case .ended(let thought):
            activity = .cleaningUp
            save(thought, transcription: session, discard: thought.endReason == .thrownAway)
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

    /// Saves the audio first, then the text when recognition finishes, then
    /// pastes it into the text box that had focus when the thought ended.
    private func save(_ thought: CapturedThought, transcription: SpeechSession?, discard: Bool) {
        let pasteTarget = focus.current()
        guard let store else {
            activity = .idle
            return
        }
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
            let id = await recorder.record(thought, meta: meta, transcription: transcription, saved: { _ in
                Task { @MainActor in await self?.refreshDatabaseInfo() }
            })
            await MainActor.run { self?.thoughtsInFlight -= 1 }
            await self?.refreshDatabaseInfo()
            await self?.showFinished()
            if let id {
                await self?.deliver(id: id, target: pasteTarget, discard: discard)
            } else {
                await self?.saveFailed()
            }
        }
    }

    private func showFinished() {
        guard activity != .hearing, let raw = lastChunk?.rawText, !raw.isEmpty else { return }
        showPreview(FinishedThought(heard: raw))
    }

    /// Shows the finished thought in Transcript mode: what was heard while
    /// it's being cleaned, then heard next to pasted for 4 seconds.
    private func showPreview(_ preview: FinishedThought?) {
        finished = preview
        overlay?.update()
        previewToken += 1
        let token = previewToken
        guard let preview else { return }
        Task {
            try? await Task.sleep(for: .seconds(preview.pasted == nil ? 15 : 4))
            if token == self.previewToken, self.activity != .hearing {
                self.finished = nil
                self.overlay?.update()
            }
        }
    }

    private func saveFailed() {
        throwAwayPending = false
        if activity == .cleaningUp { activity = waiting == nil ? .idle : .textWaiting }
    }

    /// Cleans a finished row's text, then pastes it or keeps it waiting.
    private func deliver(id: Int64, target: PasteTarget?, discard: Bool) async {
        guard let store, let row = try? await store.chunk(id: id) else { return }
        defer {
            throwAwayPending = false
            if activity == .cleaningUp { activity = waiting == nil ? .idle : .textWaiting }
            // Check the lease and the active model after each thought.
            Task { await cleanupIdleCheck() }
        }
        if discard {
            try? await store.markDiscarded(id: id)
            log(.info, "paste", "Thrown away, not pasted (#\(id))")
            return
        }
        guard row.status == "transcribed", let raw = row.rawText, !raw.isEmpty else {
            try? await store.markPaste(id: id, status: "empty", text: nil)
            return
        }
        let cleaned = await clean(raw, id: id)
        // Throw away pressed while the text was being made.
        if throwAwayPending {
            try? await store.markDiscarded(id: id)
            showPreview(nil)
            log(.info, "paste", "Thrown away, not pasted (#\(id))")
            return
        }
        let text = cleaned.pasteText
        lastDelivered = (id, text)
        if previewMode == .transcript, activity != .hearing {
            showPreview(FinishedThought(heard: raw, pasted: text, outcome: cleaned.outcome))
        }
        guard let target else {
            hold(WaitingText(id: id, text: text, reason: .targetMoved))
            return
        }
        let outcome = await paster.paste(text, into: target)
        record(outcome, id: id, text: text, target: target)
    }

    /// Cleans the text with the local model, or falls back to the raw text,
    /// and records which in the row and the log.
    private func clean(_ raw: String, id: Int64) async -> ThoughtCleanup {
        let result = await cleanup?.clean(raw)
            ?? .raw(raw, .noModel, detail: "cleanup-prompt.json is missing from the app.")
        try? await store?.markCleanup(id: id, result.record)
        let model = result.modelID.map { " with \($0)" } ?? ""
        if result.outcome == .cleaned {
            await store?.log(.info, "cleanup", "Cleaned \(raw.count) → \(result.pasteText.count) characters\(model) "
                + "in \(result.milliseconds) ms (\(result.detail))", chunkID: id)
        } else {
            await store?.log(.warning, "cleanup", "Pasting the raw text: \(result.outcome.rawValue)\(model) after "
                + "\(result.milliseconds) ms. \(result.detail)", chunkID: id)
        }
        return result
    }

    /// Follows the training lease and loads the active model when idle.
    func cleanupIdleCheck() async {
        guard let cleanup else { return }
        await cleanup.idleCheck(busy: activity == .hearing || thoughtsInFlight > 0)
        cleanupSnapshot = await cleanup.snapshot
    }

    /// Re-reads what Settings → Model shows.
    func refreshModelInfo() async {
        guard let store else { return }
        modelOverview = await ModelOverview.read(store: store)
        cleanupSnapshot = await cleanup?.snapshot
    }

    private func record(_ outcome: PasteOutcome, id: Int64, text: String, target: PasteTarget?) {
        let app = target?.appName ?? "?"
        switch outcome {
        case .pasted:
            if waiting?.id == id { waiting = nil }
            Task { try? await store?.markPaste(id: id, status: "pasted", text: text) }
            log(.info, "paste", "Pasted \(text.count) characters into \(app) (#\(id))")
        case .waiting(let reason):
            hold(WaitingText(id: id, text: text, reason: reason))
            log(.warning, "paste", "Not pasted into \(app): \(reason.rawValue) (#\(id))")
        }
    }

    private func hold(_ text: WaitingText) {
        waiting = text
        if activity != .hearing { activity = .textWaiting }
        Task { try? await store?.markPaste(id: text.id, status: "waiting", text: nil) }
    }

    /// Paste here: pastes the waiting (or last) text into whatever has focus
    /// once the panel has closed.
    func pasteHere() {
        guard let (id, text) = textToPasteAgain() else { return }
        // Give focus back to the app you were in before opening the panel.
        if NSApp.isActive { NSApp.hide(nil) }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            let target = focus.current()
            let outcome = await paster.pasteHere(text)
            record(outcome, id: id, text: text, target: target)
            if outcome == .pasted, activity == .textWaiting { activity = .idle }
        }
    }

    /// Copy: puts the waiting text on the clipboard to keep.
    func copyWaiting() {
        guard let waiting else { return }
        SystemClipboard().copy(waiting.text)
        Task { try? await store?.markPaste(id: waiting.id, status: "copied", text: waiting.text) }
        self.waiting = nil
        if activity == .textWaiting { activity = .idle }
    }

    /// Throw away: ends the thought in progress, or drops waiting text.
    func throwAway() {
        if activity == .hearing {
            capture.finishThought(.thrownAway)
        } else if activity == .cleaningUp {
            throwAwayPending = true
        } else if let waiting {
            Task { try? await store?.markDiscarded(id: waiting.id) }
            log(.info, "paste", "Waiting text thrown away (#\(waiting.id))")
            self.waiting = nil
            if activity == .textWaiting { activity = .idle }
        }
    }

    private func textToPasteAgain() -> (Int64, String)? {
        if let waiting { return (waiting.id, waiting.text) }
        if let lastDelivered, lastDelivered.id == lastChunk?.id { return lastDelivered }
        if let last = lastChunk, last.status == "transcribed", let text = last.rawText, !text.isEmpty {
            return (last.id, text)
        }
        return nil
    }

    private func hotkeyPressed(_ action: HotkeyAction) {
        switch action {
        case .startStop:
            capture.hotkey()
        case .pasteLast:
            guard let (id, text) = textToPasteAgain() else { return }
            Task {
                let target = focus.current()
                let outcome = await paster.pasteHere(text)
                record(outcome, id: id, text: text, target: target)
                if outcome == .pasted, activity == .textWaiting { activity = .idle }
            }
        case .throwAway:
            throwAway()
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

    func setHotkey(_ newHotkey: Hotkey?, for action: HotkeyAction) {
        hotkeyErrors[action] = nil
        if let newHotkey, let other = hotkeys.first(where: { $0.key != action && $0.value == newHotkey })?.key {
            hotkeyErrors[action] = "\(newHotkey.display) is already used for \(other.title)."
            hotkeyCenter.register(hotkeys[action], for: action)
            return
        }
        if hotkeyCenter.register(newHotkey, for: action) {
            hotkeys[action] = newHotkey
            preferences.setHotkey(newHotkey, for: action)
        } else {
            hotkeyErrors[action] = "\(newHotkey?.display ?? "That shortcut") is already used by another app."
            hotkeyCenter.register(hotkeys[action], for: action)
        }
    }

    /// Turns a hotkey off while a new one is being recorded, so pressing
    /// the old one doesn't trigger it.
    func pauseHotkey(_ action: HotkeyAction) {
        hotkeyCenter.unregister(action)
    }

    func resumeHotkey(_ action: HotkeyAction) {
        hotkeyCenter.register(hotkeys[action], for: action)
    }

    // MARK: Updates

    func checkForUpdates() async {
        if case .building = updateState { return }
        updateState = .checking
        updateState = await updater.check()
        log(.info, "update", "Check: \(Self.describe(updateState))")
    }

    /// Builds the update in a staging folder. The installed app keeps
    /// working; nothing changes until Restart to Update.
    func updateNow() {
        guard case .available(let commit, _, _) = updateState else { return }
        updateState = .building(commit: commit)
        log(.info, "update", "Building \(commit.prefix(7))")
        Task {
            updateState = await updater.build()
            log(updateState.isFailure ? .error : .info, "update", "Build: \(Self.describe(updateState))")
        }
    }

    /// Hands over to install.sh --activate, which waits for this app to
    /// quit, swaps the new one in whole, and opens it.
    func restartToUpdate() {
        guard case .ready(_, let stageDir) = updateState else { return }
        let command = updater.restartCommand(stageDir: stageDir, pid: ProcessInfo.processInfo.processIdentifier)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = command.environment
        let logURL = URL(fileURLWithPath: updater.logPath).deletingLastPathComponent().appendingPathComponent("activate.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = handle
            process.standardError = handle
        }
        do {
            try process.run()
            log(.info, "update", "Restarting into \(stageDir)")
            NSApp.terminate(nil)
        } catch {
            updateState = .failed("Couldn't start the update: \(error)", log: nil)
        }
    }

    private static func describe(_ state: UpdateState) -> String {
        switch state {
        case .unknown: "not checked"
        case .checking: "checking"
        case .upToDate(let commit): "up to date at \(commit.prefix(7))"
        case .notOnBranch(let reason): reason
        case .available(let commit, let changes, _): "\(changes) change(s) up to \(commit.prefix(7))"
        case .building(let commit): "building \(commit.prefix(7))"
        case .ready(let commit, _): "ready: \(commit.prefix(7))"
        case .failed(let message, _): message
        }
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

/// A thought that just ended, for the Transcript preview.
struct FinishedThought: Equatable {
    let heard: String
    /// Nil while the text is being cleaned.
    var pasted: String?
    var outcome: CleanupOutcome?
}

struct WaitingText: Equatable {
    let id: Int64
    let text: String
    let reason: WaitReason
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

extension UpdateState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
