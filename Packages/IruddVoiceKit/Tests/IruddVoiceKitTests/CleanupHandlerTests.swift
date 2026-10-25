import Foundation
import Testing
@testable import IruddVoiceKit

/// Stands in for CleanupEngine: same LoadSequence rules, sleeps instead of
/// MLX. Each generated "token" takes `tokenTime`, and generation checks the
/// deadline between tokens like the engine does.
actor FakeBackend: CleanupBackend {
    var sequence = LoadSequence()
    var loaded: String?
    var loadTime: [String: Duration] = [:]
    /// Like a CleanupEngine whose drafter loaded, or didn't (the reason).
    var drafting = false
    var drafterProblem: String?
    let tokenTime: Duration
    let tokensPerReply: Int

    init(tokenTime: Duration = .milliseconds(50), tokensPerReply: Int = 100) {
        self.tokenTime = tokenTime
        self.tokensPerReply = tokensPerReply
    }

    func setLoadTime(_ id: String, _ time: Duration) {
        loadTime[id] = time
    }

    func setDrafter(drafting: Bool, problem: String?) {
        self.drafting = drafting
        drafterProblem = problem
    }

    func load(folder: URL, expectedID: String?, verify: Bool, order: UInt64) async throws -> LoadedModel {
        guard sequence.start(order) else { throw CleanupBackendError.superseded }
        loaded = nil
        let id = folder.lastPathComponent
        try await Task.sleep(for: loadTime[id] ?? .milliseconds(10))
        guard sequence.isCurrent(order) else { throw CleanupBackendError.superseded }
        loaded = id
        return LoadedModel(id: id, seconds: 0.01, drafting: drafting, drafterProblem: drafterProblem)
    }

    func unload(order: UInt64) async {
        guard sequence.start(order) else { return }
        loaded = nil
    }

    func clean(transcript: String, vocabulary: [String], deadline: ContinuousClock.Instant) async throws -> CleanResponse {
        var tokens = 0
        while tokens < tokensPerReply {
            if ContinuousClock.now >= deadline {
                return CleanResponse(reply: nil, timedOut: true, generatedTokens: tokens)
            }
            try await Task.sleep(for: tokenTime)
            tokens += 1
        }
        return CleanResponse(reply: #"{"cleaned": "ok"}"#, generatedTokens: tokens)
    }
}

final class HandlerHost: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let handler: CleanupServiceHandler

    init(backend: FakeBackend) throws {
        handler = CleanupServiceHandler(prompt: try loadPrompt(), backend: backend,
                                        modelsFolder: URL(fileURLWithPath: "/models"))
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = CleanupInterface.make()
        connection.exportedObject = handler
        connection.resume()
        return true
    }
}

struct CleanupHandlerTests {
    @Test func statusSaysWhetherTheModelDrafts() async throws {
        let backend = FakeBackend()
        let host = try HandlerHost(backend: backend)
        let client = CleanupClient(endpoint: host.listener.endpoint)
        await backend.setDrafter(drafting: true, problem: nil)
        let drafting = try await client.load(LoadRequest(modelID: "m"))
        #expect(drafting.status.state == .ready && drafting.status.drafting == true)
        #expect(drafting.status.drafterProblem == nil)

        // The drafter didn't load: still ready, with the reason.
        await backend.setDrafter(drafting: false, problem: "the drafter didn't load: Invalid JSON")
        let plain = try await client.load(LoadRequest(modelID: "m"))
        #expect(plain.status.state == .ready && plain.status.drafting == false && plain.error == nil)
        #expect(try await client.status().drafterProblem == "the drafter didn't load: Invalid JSON")
    }

    @Test func aLateCleanupStopsAtItsDeadlineAndDoesntBlockTheNext() async throws {
        // 100 tokens × 50 ms = 5 s if nothing stopped it.
        let backend = FakeBackend()
        let host = try HandlerHost(backend: backend)
        let client = CleanupClient(endpoint: host.listener.endpoint)
        _ = try await client.load(LoadRequest(modelID: "m"))
        let start = ContinuousClock.now
        let first = try await client.clean(CleanRequest(transcript: "x", deadlineSeconds: 0.3))
        #expect(first.timedOut && first.reply == nil)
        let second = try await client.clean(CleanRequest(transcript: "y", deadlineSeconds: 0.3))
        #expect(second.timedOut)
        #expect(ContinuousClock.now - start < .seconds(1.5), "two timed-out cleanups took \(ContinuousClock.now - start)")
    }

    @Test func waitingCountsAgainstTheDeadline() async throws {
        let backend = FakeBackend()
        let host = try HandlerHost(backend: backend)
        let client = CleanupClient(endpoint: host.listener.endpoint)
        _ = try await client.load(LoadRequest(modelID: "m"))
        async let first = client.clean(CleanRequest(transcript: "x", deadlineSeconds: 0.5))
        async let second = client.clean(CleanRequest(transcript: "y", deadlineSeconds: 0.5))
        let start = ContinuousClock.now
        let results = try await [first, second]
        #expect(results.allSatisfy { $0.timedOut })
        // Both deadlines run from arrival, so both end near 0.5 s, not 1 s.
        #expect(ContinuousClock.now - start < .seconds(1.2))
    }

    @Test func unloadDuringALoadLeavesNothingLoaded() async throws {
        let backend = FakeBackend()
        await backend.setLoadTime("big", .milliseconds(400))
        let host = try HandlerHost(backend: backend)
        let client = CleanupClient(endpoint: host.listener.endpoint)
        async let load = client.load(LoadRequest(modelID: "big"))
        try await Task.sleep(for: .milliseconds(100))
        let unloaded = try await client.unload()
        #expect(unloaded.state == .empty)
        let loadResponse = try await load
        #expect(loadResponse.error == CleanupBackendError.superseded.localizedDescription)
        #expect(await backend.loaded == nil)
        #expect(try await client.status().state == .empty)
    }

    @Test func theNewerOfTwoLoadsWins() async throws {
        let backend = FakeBackend()
        await backend.setLoadTime("slow", .milliseconds(400))
        await backend.setLoadTime("fast", .milliseconds(20))
        let host = try HandlerHost(backend: backend)
        let client = CleanupClient(endpoint: host.listener.endpoint)
        async let slow = client.load(LoadRequest(modelID: "slow"))
        try await Task.sleep(for: .milliseconds(100))
        let fast = try await client.load(LoadRequest(modelID: "fast"))
        #expect(fast.status.state == .ready && fast.status.modelID == "fast")
        let slowResponse = try await slow
        #expect(slowResponse.error != nil)
        #expect(await backend.loaded == "fast")
        let status = try await client.status()
        #expect(status.state == .ready && status.modelID == "fast")
    }

    @Test func anOlderUnloadArrivingLateDoesNothing() async {
        var sequence = LoadSequence()
        let loadStarts = sequence.start(2)     // load #2 starts
        let unloadStarts = sequence.start(1)   // unload #1 reaches the backend after it
        #expect(loadStarts && !unloadStarts)
        #expect(sequence.isCurrent(2))
        #expect(sequence.next == 3)
    }

    @Test func aBadRequestChangesNothing() async throws {
        let backend = FakeBackend()
        let host = try HandlerHost(backend: backend)
        let client = CleanupClient(endpoint: host.listener.endpoint)
        _ = try await client.load(LoadRequest(modelID: "m"))
        let bad = try await client.load(LoadRequest(modelID: "../voice"))
        #expect(bad.error != nil)
        #expect(bad.status.state == .ready && bad.status.modelID == "m")
        #expect(await backend.loaded == "m")
    }
}
