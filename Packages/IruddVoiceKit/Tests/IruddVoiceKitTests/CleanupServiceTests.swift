import Foundation
import Testing
@testable import IruddVoiceKit

/// A stand-in for the cleanup helper: answers from memory, or never.
final class FakeCleanupService: NSObject, CleanupServiceProtocol, @unchecked Sendable {
    var loaded: String?
    var hang = false
    /// Drop the connection from the service side in the middle of `clean`.
    var dropConnection = false

    func status(reply: @escaping @Sendable (Data) -> Void) {
        reply(encode(CleanupStatus(state: loaded == nil ? .empty : .ready, modelID: loaded)))
    }

    func load(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        let request = try! JSONDecoder().decode(LoadRequest.self, from: request)
        loaded = request.modelID
        reply(encode(LoadResponse(status: CleanupStatus(state: .ready, modelID: loaded), loadSeconds: 1.5)))
    }

    func clean(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        if hang { return }
        if dropConnection {
            dropConnection = false
            NSXPCConnection.current()?.invalidate()
            return
        }
        let request = try! JSONDecoder().decode(CleanRequest.self, from: request)
        let cleaned = CleanupPrompt.jsonString(request.transcript.capitalized + " (" + request.vocabulary.joined(separator: ",") + ")")
        reply(encode(CleanResponse(reply: "{\"cleaned\": \(cleaned)}", promptTokens: 300, generatedTokens: 12)))
    }

    func unload(reply: @escaping @Sendable (Data) -> Void) {
        loaded = nil
        reply(encode(CleanupStatus(state: .empty)))
    }

    private func encode<T: Encodable>(_ value: T) -> Data {
        try! JSONEncoder().encode(value)
    }
}

/// Runs the protocol over a real in-process XPC connection.
final class ListenerHost: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let service = FakeCleanupService()

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = CleanupInterface.make()
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

struct CleanupServiceTests {
    @Test func roundTrip() async throws {
        let host = ListenerHost()
        let client = CleanupClient(endpoint: host.listener.endpoint)
        #expect(try await client.status().state == .empty)
        let loaded = try await client.load(LoadRequest(modelID: "qwen3.5-2b-base-q4"))
        #expect(loaded.status == CleanupStatus(state: .ready, modelID: "qwen3.5-2b-base-q4"))
        #expect(loaded.loadSeconds == 1.5)
        let response = try await client.clean(CleanRequest(transcript: "run the \"tests\"", vocabulary: ["SwiftUI"]))
        #expect(response.promptTokens == 300)
        let reply = CleanupReply.parse(try #require(response.reply), hitLimit: response.hitLimit)
        #expect(reply.cleaned == "Run The \"Tests\" (SwiftUI)")
        #expect(try await client.unload().state == .empty)
    }

    @Test func timesOut() async throws {
        let host = ListenerHost()
        host.service.hang = true
        let client = CleanupClient(endpoint: host.listener.endpoint)
        let start = ContinuousClock.now
        await #expect(throws: CleanupClientError.timedOut) {
            try await client.clean(CleanRequest(transcript: "x"), timeout: .milliseconds(200))
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func timeoutFollowsTheDeadline() async throws {
        let host = ListenerHost()
        host.service.hang = true  // ignores its deadline entirely
        let client = CleanupClient(endpoint: host.listener.endpoint)
        let start = ContinuousClock.now
        await #expect(throws: CleanupClientError.timedOut) {
            try await client.clean(CleanRequest(transcript: "x", deadlineSeconds: 0.2))
        }
        let waited = ContinuousClock.now - start
        // The deadline plus the margin, not the 5 s default.
        #expect(waited >= .milliseconds(1100) && waited < .seconds(3), "waited \(waited)")
    }

    @Test func reconnectsAfterTheHelperDropsTheConnection() async throws {
        let host = ListenerHost()
        let client = CleanupClient(endpoint: host.listener.endpoint)
        _ = try await client.load(LoadRequest(modelID: "m"))
        host.service.dropConnection = true
        await #expect(throws: CleanupClientError.self) {
            try await client.clean(CleanRequest(transcript: "x"), timeout: .seconds(2))
        }
        // The next call opens a new connection instead of failing for good.
        #expect(try await client.status().state == .ready)
        let response = try await client.clean(CleanRequest(transcript: "run it"))
        #expect(response.reply != nil)
    }

    @Test func lostHelperIsAnError() async throws {
        let host = ListenerHost()
        let client = CleanupClient(endpoint: host.listener.endpoint)
        _ = try await client.status()
        host.listener.invalidate()
        // An invalidated anonymous listener drops the connection; the call
        // fails (or times out) rather than hanging.
        await #expect(throws: CleanupClientError.self) {
            let other = CleanupClient(endpoint: host.listener.endpoint)
            _ = try await other.status(timeout: .seconds(1))
        }
    }
}
