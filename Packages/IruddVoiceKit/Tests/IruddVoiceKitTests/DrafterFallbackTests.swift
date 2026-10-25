import Foundation
import Testing
@testable import IruddVoiceKit

/// `DrafterFallback` with stand-ins for the drafter path and the plain path,
/// as CleanupEngine uses it for loading and for starting a generation.
struct DrafterFallbackTests {
    struct Broken: Error, LocalizedError {
        var errorDescription: String? { "drafter/config.json isn't valid JSON" }
    }

    struct PlainFailed: Error {}

    actor Calls {
        var names: [String] = []
        func add(_ name: String) { names.append(name) }
    }

    @Test func usesTheDrafterPathWhenItWorks() async throws {
        let calls = Calls()
        let (value, problem) = try await DrafterFallback.run({
            await calls.add("drafted")
            return "drafted model"
        }, otherwise: {
            await calls.add("plain")
            return "plain model"
        })
        #expect(value == "drafted model" && problem == nil)
        #expect(await calls.names == ["drafted"])
    }

    @Test func loadsThePlainWayWhenTheDrafterFails() async throws {
        let calls = Calls()
        let (value, problem) = try await DrafterFallback.run({ () async throws -> String in
            await calls.add("drafted")
            throw Broken()
        }, otherwise: {
            await calls.add("plain")
            return "plain model"
        })
        #expect(value == "plain model")
        #expect(problem == "drafter/config.json isn't valid JSON")
        #expect(await calls.names == ["drafted", "plain"])
    }

    @Test func aPlainFailureIsARealFailure() async {
        await #expect(throws: PlainFailed.self) {
            _ = try await DrafterFallback.run({ () async throws -> String in throw Broken() },
                                              otherwise: { throw PlainFailed() })
        }
    }

    @Test func cancellingIsntADrafterProblem() async {
        let calls = Calls()
        await #expect(throws: CancellationError.self) {
            _ = try await DrafterFallback.run({ () async throws -> String in throw CancellationError() },
                                              otherwise: {
                                                  await calls.add("plain")
                                                  return "plain model"
                                              })
        }
        #expect(await calls.names.isEmpty)
    }

    /// Starting a generation: a speculative iterator that can't start
    /// becomes the plain iterator, with the reason.
    @Test func startsThePlainIteratorWhenDraftingCantStart() throws {
        let fine = try DrafterFallback.run({ "speculative" as String? }, otherwise: { nil })
        #expect(fine.value == "speculative" && fine.problem == nil)
        let failed = try DrafterFallback.run({ () throws -> String? in throw Broken() }, otherwise: { nil })
        #expect(failed.value == nil && failed.problem == "drafter/config.json isn't valid JSON")
    }

    @Test func anErrorWithoutADescriptionStillGivesAReason() throws {
        struct Quiet: Error {}
        let result = try DrafterFallback.run({ () throws -> Int in throw Quiet() }, otherwise: { 1 })
        #expect(result.value == 1 && result.problem?.isEmpty == false)
    }
}
