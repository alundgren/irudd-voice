import Foundation

/// The app's side of the cleanup model: which model the helper has, the
/// training lease, and the status keys the CLI reads (shared/app-state.md).
///
/// - `idleCheck` runs every 10 s while the app runs, and after each
///   thought. It writes the `cleanup.checked_at` heartbeat, follows the
///   lease, checks the helper still has the model, and loads the active
///   model (or the default) when it differs. It never loads or unloads
///   while a thought is in progress.
/// - `clean` cleans one thought, or returns the raw text and why.
public actor CleanupCoordinator {
    /// `cleanup.status` values (shared/app-state.md).
    public enum ModelState: Equatable, Sendable {
        case unloaded
        case loading(String)
        case loaded(String)
        case unloadedForTraining
        case failed(String)

        public var statusValue: String {
            switch self {
            case .unloaded: "unloaded"
            case .loading: "loading"
            case .loaded: "loaded"
            case .unloadedForTraining: "unloaded-for-training"
            case .failed(let reason): "failed: \(reason)"
            }
        }
    }

    /// What Settings → Model shows.
    public struct Snapshot: Equatable, Sendable {
        public var state: ModelState
        public var since: Date
        public var loadedModel: String?
        /// The helper's memory footprint at the last check.
        public var helperBytes: UInt64?
        public var leaseUntil: Date?
        /// The active model couldn't be loaded, so the default is used.
        public var activeProblem: ModelProblem?
    }

    /// A model that couldn't be loaded, and why, in plain words.
    public struct ModelProblem: Equatable, Sendable {
        public var id: String
        public var reason: String
    }

    /// How long to wait before trying a model again after the helper
    /// didn't answer three loads in a row.
    public static let loadRetrySeconds: TimeInterval = 600

    public enum Keys {
        public static let unloadUntil = "cleanup.unload_until"
        public static let loadedModel = "cleanup.loaded_model"
        public static let status = "cleanup.status"
        public static let statusAt = "cleanup.status_at"
        public static let checkedAt = "cleanup.checked_at"
    }

    /// `cleanup.checked_at` is written at most this often (seconds).
    public static let heartbeatInterval: TimeInterval = 5

    private let helper: any CleanupHelper
    private let store: ChunkStore
    private let prompt: CleanupPrompt
    private let modelsFolder: URL
    private let vocabularyFile: URL
    private let defaultModelID: String
    private let now: @Sendable () -> Date

    private var state: ModelState = .unloaded
    private var stateSince: Date
    private var loadedModel: String?
    private var terms: [String] = []
    private var helperBytes: UInt64?
    private var leaseUntil: Date?
    /// Folders whose checksums the helper checked in this run, by id and
    /// manifest date, so a reload after a crash doesn't hash gigabytes again.
    private var verified: Set<String> = []
    /// Folders the helper refused (or that are missing), by id → manifest
    /// date; not retried until the manifest changes.
    private var refusedLoads: [String: String] = [:]
    /// Loads that failed because the helper didn't answer, by id.
    private var loadTries: [String: Int] = [:]
    /// After three such failures, not tried again until this time.
    private var retryAt: [String: Date] = [:]
    private var activeProblem: ModelProblem?
    private var thoughtsCleaning = 0
    private var checking = false
    private var written: (status: String?, loaded: String?) = (nil, nil)
    private var lastHeartbeat: Date?

    public init(helper: any CleanupHelper, store: ChunkStore, prompt: CleanupPrompt,
                modelsFolder: URL = ModelPaths.modelsFolder, vocabularyFile: URL = ModelPaths.vocabularyFile,
                defaultModelID: String = CleanupDefaults.modelID, now: @escaping @Sendable () -> Date = Date.init) {
        self.helper = helper
        self.store = store
        self.prompt = prompt
        self.modelsFolder = modelsFolder
        self.vocabularyFile = vocabularyFile
        self.defaultModelID = defaultModelID
        self.now = now
        stateSince = now()
    }

    public var snapshot: Snapshot {
        Snapshot(state: state, since: stateSince, loadedModel: loadedModel, helperBytes: helperBytes,
                 leaseUntil: leaseUntil, activeProblem: activeProblem)
    }

    // MARK: Idle check

    /// Follows the lease and loads the model the app should have. `busy`:
    /// a thought is being heard or transcribed, so nothing is loaded or
    /// unloaded now (the check after that thought does it).
    public func idleCheck(busy: Bool) async {
        // Every check is a heartbeat, even one that finds a thought in
        // progress or another check still loading a model.
        await heartbeat()
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let busy = busy || thoughtsCleaning > 0

        if let lease = await activeLease() {
            leaseUntil = lease
            // Checked again with no await before the unload: a thought that
            // started cleaning meanwhile finishes first.
            guard !busy, thoughtsCleaning == 0, state != .unloadedForTraining else { return }
            await unloadForTraining()
            return
        }
        leaseUntil = nil

        await checkHelper()
        guard !busy else {
            await writeStatus()
            return
        }

        let active = (try? await store.activeModel().modelID) ?? nil
        if activeProblem != nil && activeProblem?.id != active { activeProblem = nil }
        let wanted = [active, defaultModelID].compactMap { $0 }.reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        for id in wanted {
            if loadedModel == id { break }
            if let refused = refusedLoads[id], refused == manifestDate(id) { continue }
            if let at = retryAt[id], now() < at { continue }
            let result = await load(id)
            if result != .failed { break }
        }
        if loadedModel == nil, case .loaded = state { setState(.unloaded) }
        await writeStatus()
    }

    /// The lease end, while it's in the future. A value that can't be read
    /// counts as no lease.
    private func activeLease() async -> Date? {
        guard let value = (try? await store.appState(Keys.unloadUntil)) ?? nil,
              let until = Self.parseTime(value), until > now() else { return nil }
        return until
    }

    private func unloadForTraining() async {
        do {
            _ = try await helper.unload(timeout: .seconds(30))
            loadedModel = nil
            setState(.unloadedForTraining)
            await log(.info, "Unloaded the cleanup model for training (lease until \(leaseUntil.map(Timestamps.string) ?? "?")).")
        } catch {
            // Not confirmed, so the CLI won't start training next to it.
            setState(.failed("couldn't unload for training: \(error.localizedDescription)"))
            await log(.error, "Couldn't unload the cleanup model for training: \(error.localizedDescription)")
        }
        await writeStatus()
    }

    /// Asks the helper what it has. A helper that restarted (after a crash)
    /// is empty, so the model is loaded again.
    private func checkHelper() async {
        do {
            let status = try await helper.status(timeout: .seconds(2))
            helperBytes = status.residentBytes
            if status.state == .ready, let id = status.modelID {
                if loadedModel != id {
                    // Loaded by a request that timed out here, but finished in the helper.
                    loadedModel = id
                    terms = readTerms()
                    setState(.loaded(id))
                }
            } else if loadedModel != nil || state == .unloadedForTraining {
                loadedModel = nil
                setState(.unloaded)
            }
        } catch {
            helperBytes = nil
            loadedModel = nil
            setState(.failed("the helper didn't answer: \(error.localizedDescription)"))
        }
    }

    private enum LoadResult { case loaded, failed, deferred }

    private func load(_ id: String) async -> LoadResult {
        // No await between this check and `.loading`: a thought that
        // starts cleaning after it sees `.loading` and pastes raw.
        guard thoughtsCleaning == 0 else { return .deferred }
        let date = manifestDate(id)
        guard let folder = ModelPaths.folder(forModel: id, in: modelsFolder),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent(ModelManifest.fileName).path)
        else {
            refusedLoads[id] = date
            let hint = id == CleanupDefaults.modelID
                ? " Run: irudd-voice models prepare \(CleanupDefaults.prepareCandidate)" : ""
            noteProblem(id, "its folder isn't in the models folder")
            setState(.failed("no model folder for \(id).\(hint)"))
            await log(.error, "No model folder for \(id) in \(modelsFolder.path).\(hint)")
            return .failed
        }
        let key = "\(id)@\(date)"
        setState(.loading(id))
        await writeStatus()
        let clock = ContinuousClock()
        let start = clock.now
        let response: LoadResponse
        do {
            response = try await helper.load(LoadRequest(modelID: id, verify: !verified.contains(key)),
                                             timeout: .seconds(180))
        } catch {
            // The helper didn't answer or stopped: three tries, then wait
            // `loadRetrySeconds` before the next ones.
            loadedModel = nil
            loadTries[id, default: 0] += 1
            if loadTries[id, default: 0] >= 3 {
                retryAt[id] = now().addingTimeInterval(Self.loadRetrySeconds)
                loadTries[id] = nil
            }
            noteProblem(id, "the cleanup helper didn't answer")
            setState(.failed("\(id): \(error.localizedDescription)"))
            await log(.error, "Couldn't load \(id): \(error.localizedDescription)")
            return .failed
        }
        helperBytes = response.status.residentBytes
        guard response.error == nil, response.status.state == .ready, response.status.modelID == id else {
            // The helper refused the folder (checksums, prompt version, …):
            // not tried again until its manifest changes.
            let reason = response.error ?? "the helper isn't ready (\(response.status.state.rawValue))"
            loadedModel = nil
            refusedLoads[id] = date
            loadTries[id] = nil
            noteProblem(id, reason)
            setState(.failed("\(id): \(reason)"))
            await log(.error, "Couldn't load \(id): \(reason)")
            return .failed
        }
        verified.insert(key)
        refusedLoads[id] = nil
        loadTries[id] = nil
        retryAt[id] = nil
        if activeProblem?.id == id { activeProblem = nil }
        loadedModel = id
        terms = readTerms()
        setState(.loaded(id))
        await log(.info, String(format: "Loaded %@ in %.1f s (%d vocabulary terms)", id,
                                (clock.now - start).inSeconds, terms.count)
                  + (response.status.drafting == true ? ", with its drafter" : ""))
        if let problem = response.status.drafterProblem {
            await log(.warning, "\(id) loaded without its drafter, so cleanup is slower: \(problem)")
        }
        lastDrafterProblem = nil
        return .loaded
    }

    /// Remembers why a model other than the default couldn't be loaded,
    /// for Settings → Model.
    private func noteProblem(_ id: String, _ reason: String) {
        if id != defaultModelID { activeProblem = ModelProblem(id: id, reason: reason) }
    }

    private func readTerms() -> [String] {
        (try? Vocabulary.terms(at: vocabularyFile, limit: prompt.vocabularyLimit)) ?? []
    }

    /// The helper process stopped. It starts again, empty, on the next call.
    public func helperStopped() async {
        loadedModel = nil
        if state != .unloadedForTraining { setState(.unloaded) }
        await writeStatus()
    }

    // MARK: Cleaning

    /// Cleans a thought's text, or returns it raw with the reason.
    public func clean(_ transcript: String) async -> ThoughtCleanup {
        thoughtsCleaning += 1
        defer { thoughtsCleaning -= 1 }
        if let lease = await activeLease() {
            leaseUntil = lease
            return .raw(transcript, .unloadedForTraining, detail: "Training holds the model lease.")
        }
        guard let model = loadedModel, case .loaded = state else {
            return .raw(transcript, .noModel, detail: "No cleanup model loaded (\(state.statusValue)).")
        }
        let result = await ThoughtCleaner(helper: helper, prompt: prompt, terms: terms, modelID: model).clean(transcript)
        // Logged once per reason, not for every thought.
        if let problem = result.drafterProblem, problem != lastDrafterProblem {
            lastDrafterProblem = problem
            await log(.warning, "Cleaned without \(model)'s drafter, so more slowly: \(problem)")
        }
        return result
    }

    /// The last drafter problem logged since the model loaded.
    private var lastDrafterProblem: String?

    // MARK: Status keys

    private func setState(_ new: ModelState) {
        guard new != state else { return }
        state = new
        stateSince = now()
    }

    /// Writes `cleanup.checked_at`, which tells the CLI the app is running
    /// (`status_at` only changes with the status). At most every
    /// `heartbeatInterval`, so the 10 s checks touch the database once each.
    private func heartbeat() async {
        let at = now()
        if let last = lastHeartbeat, at >= last, at.timeIntervalSince(last) < Self.heartbeatInterval { return }
        lastHeartbeat = at
        do {
            try await store.setAppState(Keys.checkedAt, Timestamps.string(at), at: at)
        } catch {
            lastHeartbeat = nil
        }
    }

    /// Writes `cleanup.status`, `cleanup.status_at` (only when the status
    /// changed) and `cleanup.loaded_model`.
    private func writeStatus() async {
        let status = state.statusValue
        let loaded = loadedModel ?? ""
        let statusChanged = written.status != status
        let loadedChanged = written.loaded != loaded
        guard statusChanged || loadedChanged else { return }
        written = (status, loaded)
        do {
            try await store.writeCleanupStatus(status: statusChanged ? status : nil, at: stateSince,
                                               loaded: loadedChanged ? loaded : nil)
        } catch {
            written = (nil, nil)
            await store.log(.error, "cleanup", "Couldn't write the cleanup status: \(error)")
        }
    }

    private func log(_ level: LogLevel, _ message: String) async {
        await store.log(level, "cleanup", message)
    }

    private func manifestDate(_ id: String) -> String {
        guard let folder = ModelPaths.folder(forModel: id, in: modelsFolder),
              let attributes = try? FileManager.default.attributesOfItem(
                atPath: folder.appendingPathComponent(ModelManifest.fileName).path),
              let date = attributes[.modificationDate] as? Date else { return "missing" }
        return "\(date.timeIntervalSince1970)-\((attributes[.size] as? NSNumber)?.intValue ?? 0)"
    }

    /// Times in `app_state`: UTC ISO 8601, with or without milliseconds.
    public static func parseTime(_ text: String) -> Date? {
        Timestamps.date(text) ?? (try? Date.ISO8601FormatStyle().parse(text))
    }
}

extension ChunkStore {
    func writeCleanupStatus(status: String?, at: Date, loaded: String?) throws {
        if let status {
            try setAppState(CleanupCoordinator.Keys.status, status, at: at)
            try setAppState(CleanupCoordinator.Keys.statusAt, Timestamps.string(at), at: at)
        }
        if let loaded {
            try setAppState(CleanupCoordinator.Keys.loadedModel, loaded, at: at)
        }
    }
}

extension Duration {
    var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
