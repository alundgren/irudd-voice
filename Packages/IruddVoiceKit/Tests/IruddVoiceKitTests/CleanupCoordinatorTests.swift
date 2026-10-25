import Foundation
import Testing
@testable import IruddVoiceKit

/// A cleanup helper that answers from a script, without XPC.
final class ScriptedHelper: CleanupHelper, @unchecked Sendable {
    private let lock = NSLock()
    private var _loaded: String?
    private var _requests: [CleanRequest] = []
    private var _loads: [LoadRequest] = []
    private var _unloads = 0
    /// Model IDs whose folder the helper refuses.
    var refuse: Set<String> = []
    /// When set, a load, a status call or a clean waits until the test
    /// opens the gate (after the call is counted).
    var loadGate: Gate?
    var statusGate: Gate?
    var cleanGate: Gate?
    private var _statusCalls = 0
    var statusCalls: Int { lock.withLock { _statusCalls } }
    /// Thrown by load (the helper didn't answer).
    var loadError: CleanupClientError?
    /// The reply to each clean request; the default echoes the transcript.
    var reply: @Sendable (CleanRequest) throws -> CleanResponse = { request in
        CleanResponse(reply: "{\"cleaned\": \(CleanupPrompt.jsonString(request.transcript))}")
    }

    var loaded: String? {
        get { lock.withLock { _loaded } }
        set { lock.withLock { _loaded = newValue } }
    }
    var requests: [CleanRequest] { lock.withLock { _requests } }
    var loads: [LoadRequest] { lock.withLock { _loads } }
    var unloads: Int { lock.withLock { _unloads } }

    func status(timeout: Duration) async throws -> CleanupStatus {
        lock.withLock { _statusCalls += 1 }
        await statusGate?.wait()
        let loaded = loaded
        return CleanupStatus(state: loaded == nil ? .empty : .ready, modelID: loaded, residentBytes: 3 << 30)
    }

    func load(_ request: LoadRequest, timeout: Duration) async throws -> LoadResponse {
        lock.withLock { _loads.append(request) }
        await loadGate?.wait()
        if let loadError { throw loadError }
        let id = request.modelID ?? ""
        if refuse.contains(id) {
            loaded = nil
            return LoadResponse(status: CleanupStatus(state: .failed, error: "checksum"), error: "model.safetensors doesn't match")
        }
        loaded = id
        return LoadResponse(status: CleanupStatus(state: .ready, modelID: id), loadSeconds: 2)
    }

    func clean(_ request: CleanRequest, timeout: Duration?) async throws -> CleanResponse {
        lock.withLock { _requests.append(request) }
        await cleanGate?.wait()
        guard loaded != nil else { return CleanResponse(reply: nil, error: "No cleanup model is loaded.") }
        return try reply(request)
    }

    func unload(timeout: Duration) async throws -> CleanupStatus {
        lock.withLock {
            _unloads += 1
            _loaded = nil
        }
        return CleanupStatus(state: .empty)
    }
}

func repoPrompt() throws -> CleanupPrompt {
    try CleanupPrompt.load(from: sharedFolder.appendingPathComponent("cleanup-prompt.json"))
}

/// Holds callers until the test opens it.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Waits until `condition` holds, checking every 5 ms, for up to 10 s.
/// Records a test issue if it never does.
func waitUntil(_ condition: @Sendable () async throws -> Bool,
               sourceLocation: SourceLocation = #_sourceLocation) async rethrows {
    let deadline = ContinuousClock.now + .seconds(10)
    while try await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("condition not met", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
}

/// A temp database, a models folder with manifests for `models`, and a
/// coordinator over a scripted helper.
struct CleanupFixture {
    let helper = ScriptedHelper()
    let store: ChunkStore
    let path: String
    let modelsFolder: URL
    let coordinator: CleanupCoordinator

    init(models: [String] = [CleanupDefaults.modelID], prompt: CleanupPrompt? = nil,
         clock: TestClock? = nil) throws {
        path = temporaryDatabasePath()
        store = try ChunkStore(path: path)
        modelsFolder = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent).appendingPathComponent("models")
        for id in models {
            let folder = modelsFolder.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        }
        coordinator = CleanupCoordinator(
            helper: helper, store: store, prompt: try prompt ?? repoPrompt(), modelsFolder: modelsFolder,
            vocabularyFile: modelsFolder.appendingPathComponent("vocabulary.json"),
            now: { @Sendable in clock?.now ?? Date() })
    }

    /// Another connection to the same file, for what the CLI would write.
    func cli() throws -> Database { try Database(path: path) }

    func state(_ key: String) async throws -> String? { try await store.appState(key) }

    func addModel(_ id: String, active: Bool = false) throws {
        let db = try cli()
        try db.query("""
            INSERT INTO models (id, base_repo, base_revision, manifest_json, created_at)
            VALUES (?, 'google/gemma-4-E2B-it', 'abc', '{}', '2026-10-25T10:00:00.000Z')
            """, [.text(id)])
        if active {
            try db.query("""
                INSERT INTO active_model (slot, model_id, changed_at) VALUES (1, ?, '2026-10-25T10:00:00.000Z')
                ON CONFLICT (slot) DO UPDATE SET model_id = excluded.model_id
                """, [.text(id)])
        }
    }

    func setLease(seconds: Double) async throws {
        try await store.setAppState(CleanupCoordinator.Keys.unloadUntil,
                                    Timestamps.string(Date().addingTimeInterval(seconds)))
    }
}

/// Distinct letter-only words ("wab", "wac", …), so the hard checks see no numbers.
func words(_ count: Int, from start: Int = 0) -> String {
    (start..<(start + count)).map { index in
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return "w" + String(letters[index / 26 % 26]) + String(letters[index % 26])
    }.joined(separator: " ")
}

struct CleanupCoordinatorTests {
    @Test func cleansWithTheDefaultModelAndThePromptDeadline() async throws {
        let fixture = try CleanupFixture()
        fixture.helper.reply = { _ in CleanResponse(reply: "{\"cleaned\": \"Change the timeout to fifty seconds, and don't touch the retries.\"}") }
        await fixture.coordinator.idleCheck(busy: false)
        #expect(fixture.helper.loads == [LoadRequest(modelID: CleanupDefaults.modelID, verify: true)])
        #expect(try await fixture.state("cleanup.status") == "loaded")
        #expect(try await fixture.state("cleanup.loaded_model") == CleanupDefaults.modelID)

        let raw = "um change the timeout to fifteen seconds no fifty seconds and don't touch the retries"
        let result = await fixture.coordinator.clean(raw)
        #expect(result.outcome == .cleaned)
        #expect(result.pasteText == "Change the timeout to fifty seconds, and don't touch the retries.")
        #expect(result.modelID == CleanupDefaults.modelID)
        #expect(result.promptVersion == "cleanup-v1")
        #expect(fixture.helper.requests.map(\.deadlineSeconds) == [5])
        #expect(fixture.helper.requests.map(\.transcript) == [raw])
    }

    /// Every way the model can fail pastes the raw text and says why.
    @Test(arguments: [
        (CleanResponse(reply: nil, timedOut: true, error: "Cleanup passed its deadline."), CleanupOutcome.timeout),
        (CleanResponse(reply: "{\"cleaned\": \"Set the time", hitLimit: true), .cutOff),
        (CleanResponse(reply: "<think>The user wants</think>{\"cleaned\": \"x\"}"), .thinkTags),
        (CleanResponse(reply: "Sure! Here's the cleaned text: set it to fifty."), .malformed),
        (CleanResponse(reply: "{\"cleaned\": \"Set the timeout to fifteen seconds.\"}"), .hardCheck),
        (CleanResponse(reply: "{\"cleaned\": \"Sure, the timeout is now fifty seconds.\"}"), .hardCheck),
        (CleanResponse(reply: "{\"cleaned\": \"\"}"), .hardCheck),
        (CleanResponse(reply: nil, error: "No cleanup model is loaded."), .helperError),
    ])
    func failurePastesRaw(response: CleanResponse, outcome: CleanupOutcome) async throws {
        let fixture = try CleanupFixture()
        fixture.helper.reply = { _ in response }
        await fixture.coordinator.idleCheck(busy: false)
        let raw = "set the timeout to fifty seconds"
        let result = await fixture.coordinator.clean(raw)
        #expect(result.outcome == outcome, "\(result.detail)")
        #expect(result.pasteText == raw)
        #expect(result.record.cleanedText == nil)
        #expect(result.record.status == outcome.rawValue)
    }

    @Test(arguments: [
        (CleanupClientError.timedOut, CleanupOutcome.timeout),
        (.interrupted, .crash),
        (.connection("gone"), .noHelper),
        (.badReply, .helperError),
    ])
    func helperErrorPastesRaw(error: CleanupClientError, outcome: CleanupOutcome) async throws {
        let fixture = try CleanupFixture()
        fixture.helper.reply = { _ in throw error }
        await fixture.coordinator.idleCheck(busy: false)
        let result = await fixture.coordinator.clean("run the tests")
        #expect(result.outcome == outcome)
        #expect(result.pasteText == "run the tests")
    }

    @Test func emptyCleanupOfFillersIsRaw() async throws {
        let fixture = try CleanupFixture()
        fixture.helper.reply = { _ in CleanResponse(reply: "{\"cleaned\": \"\"}") }
        await fixture.coordinator.idleCheck(busy: false)
        let result = await fixture.coordinator.clean("um uh")
        #expect(result.outcome == .empty)
        #expect(result.pasteText == "um uh")
    }

    @Test func noModelPastesRaw() async throws {
        let fixture = try CleanupFixture(models: [])
        await fixture.coordinator.idleCheck(busy: false)
        #expect(fixture.helper.loads.isEmpty)
        let status = try #require(try await fixture.state("cleanup.status"))
        #expect(status.hasPrefix("failed: no model folder for gemma-4-e2b-base-q4."))
        #expect(status.contains("irudd-voice models prepare gemma-4-e2b"))
        let result = await fixture.coordinator.clean("hello there")
        #expect(result.outcome == .noModel)
        #expect(result.pasteText == "hello there")
        #expect(fixture.helper.requests.isEmpty)
    }

    @Test func longThoughtIsCleanedInPiecesAndPastedOnce() async throws {
        let fixture = try CleanupFixture()
        fixture.helper.reply = { request in
            CleanResponse(reply: "{\"cleaned\": \(CleanupPrompt.jsonString(request.transcript.uppercased()))}")
        }
        await fixture.coordinator.idleCheck(busy: false)
        // 450 words in 45 sentences of 10.
        let raw = (0..<45).map { words(10, from: $0 * 10) + "." }.joined(separator: " ")
        let result = await fixture.coordinator.clean(raw)
        #expect(result.outcome == .cleaned, "\(result.detail)")
        #expect(result.pieces == 4)
        let sent = fixture.helper.requests.map(\.transcript)
        #expect(sent.count == 4)
        #expect(sent.allSatisfy { $0.split(separator: " ").count <= ThoughtPieces.maxWords })
        #expect(sent.allSatisfy { $0.hasSuffix(".") })
        #expect(sent.joined(separator: " ") == raw)
        #expect(result.pasteText == raw.uppercased())
    }

    @Test func onePieceFailingPastesTheWholeThoughtRaw() async throws {
        let fixture = try CleanupFixture()
        fixture.helper.reply = { request in
            if request.transcript.contains(words(1, from: 200)) {
                return CleanResponse(reply: "<think>hmm</think>")
            }
            return CleanResponse(reply: "{\"cleaned\": \(CleanupPrompt.jsonString(request.transcript))}")
        }
        await fixture.coordinator.idleCheck(busy: false)
        let raw = (0..<45).map { words(10, from: $0 * 10) + "." }.joined(separator: " ")
        let result = await fixture.coordinator.clean(raw)
        #expect(result.outcome == .thinkTags, "\(result.detail)")
        #expect(result.pasteText == raw)
        #expect(result.detail.contains("piece 2 of 4"))
        // It stops at the failing piece.
        #expect(fixture.helper.requests.count == 2)
    }

    @Test func trainingLeaseUnloadsAndReloadsWhenItEnds() async throws {
        let fixture = try CleanupFixture()
        await fixture.coordinator.idleCheck(busy: false)
        #expect(fixture.helper.loaded == CleanupDefaults.modelID)

        try await fixture.setLease(seconds: 120)
        // A thought that arrives before the idle check is already raw.
        let early = await fixture.coordinator.clean("run the tests")
        #expect(early.outcome == .unloadedForTraining)
        #expect(early.pasteText == "run the tests")
        #expect(fixture.helper.requests.isEmpty)

        await fixture.coordinator.idleCheck(busy: false)
        #expect(fixture.helper.unloads == 1)
        #expect(fixture.helper.loaded == nil)
        #expect(try await fixture.state("cleanup.status") == "unloaded-for-training")
        #expect(try await fixture.state("cleanup.loaded_model") == "")
        let at = try #require(try await fixture.state("cleanup.status_at"))
        #expect(Timestamps.date(at) != nil)

        // Later checks while the lease holds change nothing.
        await fixture.coordinator.idleCheck(busy: false)
        #expect(fixture.helper.unloads == 1)
        #expect(fixture.helper.loads.count == 1)
        #expect(try await fixture.state("cleanup.status_at") == at)

        // The CLI deletes the lease when done: the next check loads again,
        // without hashing the folder a second time.
        try await fixture.store.deleteAppState(CleanupCoordinator.Keys.unloadUntil)
        await fixture.coordinator.idleCheck(busy: false)
        #expect(fixture.helper.loads.last == LoadRequest(modelID: CleanupDefaults.modelID, verify: false))
        #expect(try await fixture.state("cleanup.status") == "loaded")
        #expect(try await fixture.state("cleanup.loaded_model") == CleanupDefaults.modelID)
        #expect(await fixture.coordinator.clean("run the tests").outcome == .cleaned)
    }

    @Test func leaseThatRanOutCountsAsNone() async throws {
        let fixture = try CleanupFixture()
        try await fixture.setLease(seconds: -1)
        await fixture.coordinator.idleCheck(busy: false)
        #expect(fixture.helper.unloads == 0)
        #expect(try await fixture.state("cleanup.status") == "loaded")
    }

    @Test func leaseWaitsForTheThoughtInProgress() async throws {
        let fixture = try CleanupFixture()
        await fixture.coordinator.idleCheck(busy: false)
        try await fixture.setLease(seconds: 120)
        await fixture.coordinator.idleCheck(busy: true)
        #expect(fixture.helper.unloads == 0)
        #expect(try await fixture.state("cleanup.status") == "loaded")
        await fixture.coordinator.idleCheck(busy: false)
        #expect(fixture.helper.unloads == 1)
    }

    @Test func heartbeatOnEveryCheckAtMostEveryFiveSeconds() async throws {
        let clock = TestClock()
        let fixture = try CleanupFixture(clock: clock)
        await fixture.coordinator.idleCheck(busy: false)
        let first = try #require(try await fixture.state("cleanup.checked_at"))
        #expect(first == Timestamps.string(clock.now))

        // Within 5 s: no write.
        clock.advance(4)
        await fixture.coordinator.idleCheck(busy: false)
        #expect(try await fixture.state("cleanup.checked_at") == first)

        // A check during a thought still writes it; status_at stays.
        let statusAt = try await fixture.state("cleanup.status_at")
        clock.advance(6)
        await fixture.coordinator.idleCheck(busy: true)
        #expect(try await fixture.state("cleanup.checked_at") == Timestamps.string(clock.now))
        #expect(try await fixture.state("cleanup.status_at") == statusAt)

        // And during the training lease.
        try await fixture.store.setAppState(CleanupCoordinator.Keys.unloadUntil,
                                            Timestamps.string(clock.now.addingTimeInterval(120)))
        clock.advance(10)
        await fixture.coordinator.idleCheck(busy: false)
        clock.advance(10)
        await fixture.coordinator.idleCheck(busy: false)
        #expect(try await fixture.state("cleanup.checked_at") == Timestamps.string(clock.now))
    }

    @Test func heartbeatWhileAnotherCheckIsLoading() async throws {
        let clock = TestClock()
        let fixture = try CleanupFixture(clock: clock)
        let gate = Gate()
        fixture.helper.loadGate = gate
        let loading = Task { await fixture.coordinator.idleCheck(busy: false) }
        await waitUntil { fixture.helper.loads.count == 1 }
        #expect(try await fixture.state("cleanup.status") == "loading")
        clock.advance(10)
        await fixture.coordinator.idleCheck(busy: false)
        #expect(try await fixture.state("cleanup.checked_at") == Timestamps.string(clock.now))
        await gate.open()
        await loading.value
        #expect(try await fixture.state("cleanup.status") == "loaded")
    }

    @Test func switchesToTheActiveModelOnlyWhenIdle() async throws {
        let trained = "gemma-4-e2b-ft-20261025-1"
        let fixture = try CleanupFixture(models: [CleanupDefaults.modelID, trained])
        await fixture.coordinator.idleCheck(busy: false)
        try fixture.addModel(trained, active: true)
        await fixture.coordinator.idleCheck(busy: true)
        #expect(fixture.helper.loaded == CleanupDefaults.modelID)
        await fixture.coordinator.idleCheck(busy: false)
        #expect(fixture.helper.loaded == trained)
        #expect(try await fixture.state("cleanup.loaded_model") == trained)
        #expect(await fixture.coordinator.clean("run the tests").modelID == trained)
    }

    @Test func refusedActiveModelFallsBackToTheDefault() async throws {
        let trained = "gemma-4-e2b-ft-20261025-1"
        let fixture = try CleanupFixture(models: [CleanupDefaults.modelID, trained])
        fixture.helper.refuse = [trained]
        try fixture.addModel(trained, active: true)
        await fixture.coordinator.idleCheck(busy: false)
        #expect(fixture.helper.loaded == CleanupDefaults.modelID)
        #expect(try await fixture.state("cleanup.status") == "loaded")
        // Settings says why the default is in use.
        #expect(await fixture.coordinator.snapshot.activeProblem
                == .init(id: trained, reason: "model.safetensors doesn't match"))
        // The refused folder isn't tried again until its manifest changes.
        await fixture.coordinator.idleCheck(busy: false)
        #expect(fixture.helper.loads.map(\.modelID) == [trained, CleanupDefaults.modelID])
        // Going back to the default clears the note.
        try fixture.cli().query("UPDATE active_model SET model_id = NULL")
        await fixture.coordinator.idleCheck(busy: false)
        #expect(await fixture.coordinator.snapshot.activeProblem == nil)
    }

    @Test func helperThatDoesntAnswerIsRetriedAfterTheBackoff() async throws {
        let clock = TestClock()
        let fixture = try CleanupFixture(clock: clock)
        fixture.helper.loadError = .timedOut
        for _ in 0..<5 {
            await fixture.coordinator.idleCheck(busy: false)
            clock.advance(10)
        }
        // Three tries, then a pause.
        #expect(fixture.helper.loads.count == 3)
        #expect(try await fixture.state("cleanup.status")?.hasPrefix("failed: ") == true)
        clock.advance(CleanupCoordinator.loadRetrySeconds)
        fixture.helper.loadError = nil
        await fixture.coordinator.idleCheck(busy: false)
        #expect(fixture.helper.loads.count == 4)
        #expect(try await fixture.state("cleanup.status") == "loaded")
    }

    /// A thought that starts cleaning while a check is still deciding: the
    /// check doesn't load, switch or unload under it.
    @Test func noLoadOrUnloadWhileAThoughtIsCleaning() async throws {
        let trained = "gemma-4-e2b-ft-20261025-1"
        let fixture = try CleanupFixture(models: [CleanupDefaults.modelID, trained])
        await fixture.coordinator.idleCheck(busy: false)

        // Switch: the active model changes while a thought is being cleaned.
        try fixture.addModel(trained, active: true)
        var gate = Gate()
        fixture.helper.cleanGate = gate
        let cleaning = Task { await fixture.coordinator.clean("run the tests") }
        await waitUntil { fixture.helper.requests.count == 1 }
        await fixture.coordinator.idleCheck(busy: false)
        #expect(fixture.helper.loaded == CleanupDefaults.modelID)
        await gate.open()
        #expect(await cleaning.value.outcome == .cleaned)
        await fixture.coordinator.idleCheck(busy: false)
        #expect(fixture.helper.loaded == trained)

        // The check waits on the helper, and a thought starts meanwhile.
        try fixture.cli().query("UPDATE active_model SET model_id = NULL")
        let statusGate = Gate()
        gate = Gate()
        fixture.helper.statusGate = statusGate
        fixture.helper.cleanGate = gate
        let calls = fixture.helper.statusCalls
        let check = Task { await fixture.coordinator.idleCheck(busy: false) }
        await waitUntil { fixture.helper.statusCalls == calls + 1 }
        let second = Task { await fixture.coordinator.clean("run the tests") }
        await waitUntil { fixture.helper.requests.count == 2 }
        await statusGate.open()
        await check.value
        #expect(fixture.helper.loaded == trained)
        await gate.open()
        #expect(await second.value.outcome == .cleaned)
        fixture.helper.statusGate = nil

        // Lease: no unload until the thought is done.
        gate = Gate()
        fixture.helper.cleanGate = gate
        let third = Task { await fixture.coordinator.clean("run the tests") }
        await waitUntil { fixture.helper.requests.count == 3 }
        try await fixture.setLease(seconds: 120)
        await fixture.coordinator.idleCheck(busy: false)
        #expect(fixture.helper.unloads == 0)
        await gate.open()
        #expect(await third.value.outcome == .cleaned)
        await fixture.coordinator.idleCheck(busy: false)
        #expect(fixture.helper.unloads == 1)
    }

    @Test func plainReasons() async throws {
        let fixture = try CleanupFixture()
        await fixture.coordinator.idleCheck(busy: false)
        fixture.helper.reply = { _ in CleanResponse(reply: #"{"cleaned": "Set the timeout to fifteen seconds."}"#) }
        let changed = await fixture.coordinator.clean("set the timeout to fifty seconds")
        #expect(changed.failedChecks == ["numbers"])
        #expect(changed.plainReason == "cleanup changed a number")
        fixture.helper.reply = { _ in CleanResponse(reply: nil, timedOut: true) }
        #expect(await fixture.coordinator.clean("run it").plainReason == "the model took too long")
        try await fixture.setLease(seconds: 120)
        #expect(await fixture.coordinator.clean("run it").plainReason == "training is using the model")
        fixture.helper.reply = { request in
            CleanResponse(reply: "{\"cleaned\": \(CleanupPrompt.jsonString(request.transcript))}")
        }
        try await fixture.store.deleteAppState(CleanupCoordinator.Keys.unloadUntil)
        #expect(await fixture.coordinator.clean("run it").plainReason == nil)
        // Every outcome but cleaned has a reason, and none shows an internal code.
        for outcome in CleanupOutcome.allCases where outcome != .cleaned {
            let reason = try #require(ThoughtCleanup.raw("x", outcome, detail: "").plainReason)
            #expect(!reason.contains("_"))
        }
    }

    @Test func reloadsAfterTheHelperRestarts() async throws {
        let fixture = try CleanupFixture()
        await fixture.coordinator.idleCheck(busy: false)
        // The helper crashed and launchd started it again, empty.
        fixture.helper.loaded = nil
        await fixture.coordinator.helperStopped()
        #expect(try await fixture.state("cleanup.status") == "unloaded")
        #expect(await fixture.coordinator.clean("run the tests").outcome == .noModel)
        await fixture.coordinator.idleCheck(busy: false)
        #expect(fixture.helper.loads.map(\.verify) == [true, false])
        #expect(await fixture.coordinator.clean("run the tests").outcome == .cleaned)
    }

    @Test func passesTheVocabulary() async throws {
        let fixture = try CleanupFixture()
        try Data(#"{"version": 1, "terms": ["SwiftUI", "irudd-voice"]}"#.utf8)
            .write(to: fixture.modelsFolder.appendingPathComponent("vocabulary.json"))
        await fixture.coordinator.idleCheck(busy: false)
        fixture.helper.reply = { _ in CleanResponse(reply: #"{"cleaned": "Open the SwiftUI view."}"#) }
        let result = await fixture.coordinator.clean("open the swift ui view")
        #expect(result.outcome == .cleaned, "\(result.detail)")
        #expect(fixture.helper.requests.first?.vocabulary == ["SwiftUI", "irudd-voice"])
    }

    @Test func recordsTheCleanupInTheRow() async throws {
        let fixture = try CleanupFixture()
        let captured = thought(seconds: 1)
        let audio = AudioEncoding.encode(samples: captured.samples, sampleRate: captured.sampleRate)
        let id = try await fixture.store.insertPending(meta: meta(for: captured), audio: audio, durationMs: 1000)
        let record = CleanupRecord(status: "cleaned", cleanedText: "Run the tests.", modelID: CleanupDefaults.modelID,
                                   milliseconds: 1234, promptVersion: "cleanup-v1")
        try await fixture.store.markCleanup(id: id, record)
        #expect(try await fixture.store.cleanupRecord(id: id) == record)
        let failed = ThoughtCleanup(raw: "run the tests", pasteText: "run the tests", outcome: .timeout,
                                    modelID: CleanupDefaults.modelID, promptVersion: "cleanup-v1",
                                    milliseconds: 6010, pieces: 1, detail: "")
        try await fixture.store.markCleanup(id: id, failed.record)
        #expect(try await fixture.store.cleanupRecord(id: id) == CleanupRecord(
            status: "timeout", cleanedText: nil, modelID: CleanupDefaults.modelID, milliseconds: 6010,
            promptVersion: "cleanup-v1"))
    }

    /// Through the real XPC client: a helper that never answers is cut off
    /// at the prompt's deadline plus the margin.
    @Test func realClientTimesOutAtThePromptDeadline() async throws {
        let host = ListenerHost()
        let client = CleanupClient(endpoint: host.listener.endpoint)
        var prompt = try repoPrompt()
        prompt.generation.timeoutSeconds = 0.2
        _ = try await client.load(LoadRequest(modelID: CleanupDefaults.modelID))
        host.service.hang = true
        let cleaner = ThoughtCleaner(helper: client, prompt: prompt, terms: [], modelID: CleanupDefaults.modelID)
        let result = await cleaner.clean("run the tests")
        #expect(result.outcome == .timeout)
        #expect(result.pasteText == "run the tests")
        #expect(result.milliseconds >= 1100 && result.milliseconds < 3000)
    }
}

struct ThoughtPiecesTests {
    @Test func shortThoughtIsOnePiece() {
        #expect(ThoughtPieces.split("  run the tests  ") == ["run the tests"])
        #expect(ThoughtPieces.split(words(120)) == [words(120)])
        #expect(ThoughtPieces.split("   ").isEmpty)
    }

    @Test func splitsAtSentenceEnds() {
        let text = (0..<30).map { words(10, from: $0 * 10) + ($0 % 2 == 0 ? "?" : ".\"") }.joined(separator: " ")
        let pieces = ThoughtPieces.split(text)
        #expect(pieces.count == 3)
        #expect(pieces.map { $0.split(separator: " ").count } == [120, 120, 60])
        #expect(pieces.joined(separator: " ") == text)
    }

    @Test func longSentenceSplitsAtClauses() {
        let clauses = (0..<10).map { words(25, from: $0 * 25) + "," }
        let text = clauses.joined(separator: " ")
        let pieces = ThoughtPieces.split(text)
        #expect(pieces.allSatisfy { $0.hasSuffix(",") })
        #expect(pieces.map { $0.split(separator: " ").count } == [100, 100, 50])
        #expect(pieces.joined(separator: " ") == text)
    }

    @Test func noPunctuationSplitsAtTheWordLimit() {
        let text = words(300)
        let pieces = ThoughtPieces.split(text)
        #expect(pieces.map { $0.split(separator: " ").count } == [120, 120, 60])
        #expect(pieces.joined(separator: " ") == text)
    }
}

struct WordDiffTests {
    @Test func strikesRemovedWords() {
        let (heard, pasted) = WordDiff.compare(
            heard: "um change the timeout to fifteen seconds no fifty seconds and don't touch the retries",
            pasted: "Change the timeout to fifty seconds, and don't touch the retries.")
        #expect(heard.filter { !$0.kept }.map(\.text) == ["um", "fifteen", "seconds", "no"])
        #expect(pasted.allSatisfy { $0.kept })
    }

    @Test func marksAddedWords() {
        let (heard, pasted) = WordDiff.compare(heard: "read me file", pasted: "README file — done")
        #expect(heard.map(\.kept) == [false, false, true])
        #expect(pasted.map(\.kept) == [false, true, true, false])
    }

    @Test func emptySides() {
        #expect(WordDiff.compare(heard: "", pasted: "x").heard.isEmpty)
        #expect(WordDiff.compare(heard: "x", pasted: "").heard == [WordDiff.Word("x", kept: false)])
    }
}

struct ModelOverviewTests {
    @Test func defaultBaseModel() async throws {
        let fixture = try CleanupFixture()
        let overview = await ModelOverview.read(store: fixture.store, modelsFolder: fixture.modelsFolder)
        #expect(overview == ModelOverview(activeID: CleanupDefaults.modelID, isDefault: true))
    }

    @Test func trainedModelWithAnEvalReport() async throws {
        let trained = "gemma-4-e2b-ft-20261025-1"
        let fixture = try CleanupFixture(models: [CleanupDefaults.modelID, trained])
        let manifest = """
            {"schema": 1, "id": "\(trained)", "family": "gemma4", "base_repo": "google/gemma-4-E2B-it",
             "base_revision": "abc", "tokenizer_sha256": "t", "chat_template_sha256": "c",
             "prompt_version": "cleanup-v1", "files": {},
             "training": {"method": "lora", "dataset_hash": "d", "chunks": 412, "layers": 16,
                          "iterations": 600, "mlx_lm_version": "0.32.2", "trained_at": "2026-10-25T12:00:00Z"},
             "created_at": "2026-10-25T12:00:00Z"}
            """
        let report = """
            {"kind": "eval-compare", "version": 1, "incumbent": {"id": "\(CleanupDefaults.modelID)"},
             "created_at": "2026-10-25T13:00:00Z",
             "summary": {"thoughts": 125, "compared": 120, "votes": {"win": 60, "loss": 40, "tie": 15, "same": 5, "split": 0, "failed": 0},
                         "decided": 100, "win_rate": 0.6,
                         "hard_checks": {"candidate_thoughts_failed": 3, "incumbent_thoughts_failed": 7, "new_failures": 0}},
             "decision": {"promotable": true, "reasons": []}}
            """
        let db = try fixture.cli()
        try db.query("""
            INSERT INTO models (id, base_repo, base_revision, manifest_json, trained_chunks, eval_report_json, created_at)
            VALUES (?, 'google/gemma-4-E2B-it', 'abc', ?, 412, ?, '2026-10-25T12:00:00.000Z')
            """, [.text(trained), .text(manifest), .text(report)])
        try db.query("""
            INSERT INTO models (id, base_repo, base_revision, manifest_json, created_at)
            VALUES (?, 'google/gemma-4-E2B-it', 'abc', '{}', '2026-10-25T10:00:00.000Z')
            """, [.text(CleanupDefaults.modelID)])
        try db.query("""
            INSERT INTO active_model (slot, model_id, previous_model_id, changed_at)
            VALUES (1, ?, ?, '2026-10-25T13:05:00.000Z')
            """, [.text(trained), .text(CleanupDefaults.modelID)])
        let overview = await ModelOverview.read(store: fixture.store, modelsFolder: fixture.modelsFolder)
        #expect(overview.activeID == trained)
        #expect(!overview.isDefault)
        #expect(overview.previousID == CleanupDefaults.modelID)
        #expect(overview.training?.chunks == 412)
        #expect(overview.training?.trainedAt == "2026-10-25T12:00:00Z")
        let eval = try #require(overview.eval)
        #expect(eval.incumbentID == CleanupDefaults.modelID)
        #expect(eval.wins == 60 && eval.decided == 100 && eval.compared == 120 && eval.thoughts == 125)
        #expect(eval.winPercent == 60)
        #expect(eval.thoughtsFailed == 3 && eval.incumbentThoughtsFailed == 7)
        #expect(eval.promotable == true)
    }

    @Test func olderReportWithoutThoughtsCountsCompared() throws {
        let eval = try #require(EvalSummary.parse("""
            {"summary": {"compared": 110, "votes": {"win": 1}, "decided": 2}}
            """))
        #expect(eval.thoughts == 110 && eval.compared == 110)
    }

    @Test func deleteAllKeepsReportsWithoutItemsAndDropsBrokenOnes() async throws {
        let fixture = try CleanupFixture()
        let db = try fixture.cli()
        try db.query("""
            INSERT INTO models (id, base_repo, base_revision, manifest_json, eval_report_json, created_at)
            VALUES ('a', 'r', 'v', '{}', '{"summary": {"thoughts": 3}, "items": [{"raw": "x"}]}', 'now'),
                   ('b', 'r', 'v', '{}', 'not json', 'now'), ('c', 'r', 'v', '{}', NULL, 'now')
            """)
        try await fixture.store.deleteAllRecordings()
        let reports = try db.query("SELECT id, eval_report_json FROM models ORDER BY id").map { $0[1].text }
        #expect(reports == [#"{"summary":{"thoughts":3}}"#, nil, nil])
    }

    @Test func notAReport() {
        #expect(EvalSummary.parse("{}") == nil)
        #expect(EvalSummary.parse("not json") == nil)
    }
}

@MainActor
struct DeliveryLineTests {
    /// Records deliveries in order.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func add(_ entry: String) { lock.withLock { entries.append(entry) } }
        var all: [String] { lock.withLock { entries } }
    }

    @Test func deliversInTheOrderThoughtsEnded() async {
        let line = DeliveryLine<String>()
        let log = Log()
        let gate = Gate()
        // A long thought A, then a short thought B that's ready first.
        line.add(make: { _ in
            await gate.wait()
            log.add("made A")
            return "A"
        }, deliver: { _, item, _ in log.add("pasted \(item)") })
        let last = line.add(make: { _ in
            log.add("made B")
            return "B"
        }, deliver: { _, item, _ in log.add("pasted \(item)") })
        #expect(line.isBusy)
        await waitUntil { log.all.contains("made B") }
        #expect(log.all == ["made B"])
        await gate.open()
        await last.value
        #expect(log.all == ["made B", "made A", "pasted A", "pasted B"])
        #expect(!line.isBusy)
    }

    @Test func throwAwayHitsTheNewestThoughtOnly() async {
        let line = DeliveryLine<String>()
        let log = Log()
        let gateA = Gate(), gateB = Gate()
        line.add(make: { _ in
            await gateA.wait()
            return "A"
        }, deliver: { _, item, thrownAway in log.add("\(item) \(thrownAway ? "discarded" : "pasted")") })
        let last = line.add(make: { _ in
            await gateB.wait()
            return "B"
        }, deliver: { _, item, thrownAway in log.add("\(item) \(thrownAway ? "discarded" : "pasted")") })
        // Throw Away while both are being cleaned: B, not A.
        #expect(line.throwAwayNewest() == 2)
        #expect(line.isThrownAway(2) && !line.isThrownAway(1))
        await gateB.open()
        await gateA.open()
        await last.value
        #expect(log.all == ["A pasted", "B discarded"])
        #expect(line.marked.isEmpty)
        // The mark went with B: the next thought isn't affected.
        let next = line.add(make: { _ in "C" }, deliver: { _, item, thrownAway in
            log.add("\(item) \(thrownAway ? "discarded" : "pasted")")
        })
        await next.value
        #expect(log.all.last == "C pasted")
        #expect(line.throwAwayNewest() == nil)
    }

    /// Throw Away while a thought is being pasted, before ⌘V: the paste
    /// asks `shouldStop` and stops. The mark goes with the delivery.
    @Test func throwAwayDuringThePasteStopsIt() async {
        let line = DeliveryLine<String>()
        let log = Log()
        let keyWait = Gate()
        line.add(make: { _ in "A" }, deliver: { number, item, thrownAway in
            log.add("pasting \(item)")
            // The paste waits for held keys, then asks.
            await keyWait.wait()
            let stop = line.shouldStop(number, at: .check)
            log.add("\(item) \(thrownAway || stop ? "stopped" : "pasted")")
        })
        await waitUntil { log.all == ["pasting A"] }
        #expect(line.throwAwayNewest() == 1)
        await keyWait.open()
        await waitUntil { @MainActor in !line.isBusy }
        #expect(log.all == ["pasting A", "A stopped"])
        #expect(line.marked.isEmpty)
    }

    /// Once the paste is past its last check (⌘V is next), Throw Away can't
    /// mark it, and no mark is left behind; a newer thought still being
    /// made is marked instead.
    @Test func throwAwayAfterTheLastCheckMarksNothing() async {
        let line = DeliveryLine<String>()
        let log = Log()
        let pasting = Gate(), makingB = Gate()
        line.add(make: { _ in "A" }, deliver: { number, item, _ in
            let stop = line.shouldStop(number, at: .beforeKeystroke)
            log.add("committed \(item)")
            await pasting.wait()
            log.add("\(item) \(stop ? "stopped" : "pasted")")
        })
        await waitUntil { log.all == ["committed A"] }
        #expect(line.throwAwayNewest() == nil)
        #expect(line.marked.isEmpty)

        let last = line.add(make: { _ in
            await makingB.wait()
            return "B"
        }, deliver: { _, item, thrownAway in log.add("\(item) \(thrownAway ? "discarded" : "pasted")") })
        #expect(line.throwAwayNewest() == 2)
        await pasting.open()
        await makingB.open()
        await last.value
        #expect(log.all == ["committed A", "A pasted", "B discarded"])
        #expect(line.marked.isEmpty)
        #expect(!line.isBusy)
    }

    @Test func reportsWhatsLeftAfterEachDelivery() async {
        let line = DeliveryLine<Int>()
        let log = Log()
        line.onDelivered = { remaining in log.add("left \(remaining)") }
        line.add(make: { $0 }, deliver: { _, _, _ in })
        let last = line.add(make: { $0 }, deliver: { _, _, _ in })
        await last.value
        #expect(log.all == ["left 1", "left 0"])
    }
}

struct ThrowAwayTargetTests {
    typealias Case = (activity: AppStatus.Activity, waiting: Bool, busy: Bool, hotkey: ThrowAwayTarget)

    /// Every combination of what the icon shows, waiting text and thoughts
    /// in flight, and what the hotkey does.
    static let hotkeyTable: [Case] = [
        (.hearing, false, false, .thoughtBeingHeard),
        (.hearing, false, true, .thoughtBeingHeard),
        (.hearing, true, false, .thoughtBeingHeard),
        (.hearing, true, true, .thoughtBeingHeard),
        (.cleaningUp, false, false, .nothing),
        (.cleaningUp, false, true, .newestInFlight),
        (.cleaningUp, true, false, .waitingText),
        // B ended after A was held: the icon says Cleaning up, so B goes.
        (.cleaningUp, true, true, .newestInFlight),
        (.textWaiting, false, false, .nothing),
        (.textWaiting, false, true, .newestInFlight),
        (.textWaiting, true, false, .waitingText),
        // A waits in Text waiting while B is still cleaning: A goes.
        (.textWaiting, true, true, .waitingText),
        (.idle, false, false, .nothing),
        (.idle, false, true, .newestInFlight),
        (.idle, true, false, .waitingText),
        (.idle, true, true, .waitingText),
    ]

    @Test(arguments: hotkeyTable.indices)
    func hotkey(row: Int) {
        let c = Self.hotkeyTable[row]
        #expect(ThrowAwayTarget.pick(.hotkey, activity: c.activity, hasWaitingText: c.waiting, deliveryBusy: c.busy)
                == c.hotkey, "\(c)")
    }

    /// The button on the waiting row always drops that text, even while
    /// hearing or while another thought is cleaning.
    @Test(arguments: hotkeyTable.indices)
    func waitingRowButton(row: Int) {
        let c = Self.hotkeyTable[row]
        #expect(ThrowAwayTarget.pick(.waitingRow, activity: c.activity, hasWaitingText: c.waiting, deliveryBusy: c.busy)
                == (c.waiting ? .waitingText : .nothing), "\(c)")
    }
}
