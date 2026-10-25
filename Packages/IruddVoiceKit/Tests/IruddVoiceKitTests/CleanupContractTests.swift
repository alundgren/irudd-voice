import Foundation
import Testing
@testable import IruddVoiceKit

/// The repo's shared/ folder, read at test time so the Swift side always
/// runs the same fixtures as the Python CLI.
let sharedFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // IruddVoiceKitTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // IruddVoiceKit
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()  // repo
    .appendingPathComponent("shared")

func loadPrompt() throws -> CleanupPrompt {
    try CleanupPrompt.load(from: sharedFolder.appendingPathComponent("cleanup-prompt.json"))
}

struct PromptBuildingCase: Decodable {
    var name: String
    var transcript: String
    var terms: [String]
    var system: String
    var user: String
}

struct HardCheckFixtures: Decodable {
    struct ReplyCase: Decodable {
        var name: String
        var reply: String
        var hit_limit: Bool
        var cleaned: String?
        var failure: String?
    }

    struct CheckCase: Decodable {
        var name: String
        var transcript: String
        var cleaned: String
        var vocabulary: [String]
        var failures: [String]
    }

    var replies: [ReplyCase]
    var checks: [CheckCase]
}

func fixture<T: Decodable>(_ name: String, _ type: T.Type) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(contentsOf: sharedFolder.appendingPathComponent("fixtures/\(name)")))
}

struct PromptBuildingTests {
    struct File: Decodable { var cases: [PromptBuildingCase] }

    static let cases: [PromptBuildingCase] = (try? fixture("prompt-building.json", File.self).cases) ?? []

    @Test func fixturesAreThere() {
        #expect(Self.cases.count >= 7)
    }

    @Test(arguments: cases.map(\.name))
    func buildsExactMessages(name: String) throws {
        let prompt = try loadPrompt()
        let item = try #require(Self.cases.first { $0.name == name })
        let messages = prompt.messages(transcript: item.transcript, terms: item.terms)
        #expect(messages.map(\.role) == ["system", "user"])
        #expect(Array(messages[0].content.utf8) == Array(item.system.utf8))
        #expect(Array(messages[1].content.utf8) == Array(item.user.utf8))
    }

    @Test func readsSettings() throws {
        let prompt = try loadPrompt()
        #expect(prompt.version == "cleanup-v1")
        #expect(prompt.generation.maxTokens == 768)
        #expect(prompt.generation.temperature == 0)
        #expect(prompt.chatTemplateOptions["enable_thinking"] == .bool(false))
        #expect(prompt.templateContext["enable_thinking"] as? Bool == false)
    }

    @Test func escapesOnlyWhatJSONNeeds() {
        #expect(CleanupPrompt.jsonString("a/b “c” \u{01}\u{1f}\t\\\"") == #""a/b “c” \u0001\u001f\t\\\"""#)
    }

    @Test func fillsInOnePass() {
        let values = ["input_json": "{rule} {input_json}", "rule": "R"]
        #expect(CleanupPrompt.fill("{input_json} / {rule} / {other} / {{rule}", values)
            == "{rule} {input_json} / R / {other} / {R")
    }

    @Test func usesTheFirstTermsOnly() throws {
        var prompt = try loadPrompt()
        prompt.vocabularyLimit = 2
        let system = prompt.messages(transcript: "x", terms: ["A", "B", "C"])[0].content
        #expect(system.hasSuffix("Vocabulary (use these spellings): A, B"))
    }
}

struct HardCheckTests {
    static let fixtures: HardCheckFixtures? = try? fixture("hard-checks.json", HardCheckFixtures.self)

    @Test func fixturesAreThere() throws {
        let fixtures = try #require(Self.fixtures)
        #expect(fixtures.replies.count >= 10)
        #expect(fixtures.checks.count >= 46)
    }

    @Test(arguments: (fixtures?.replies ?? []).map(\.name))
    func readsReply(name: String) throws {
        let item = try #require(Self.fixtures?.replies.first { $0.name == name })
        let reply = CleanupReply.parse(item.reply, hitLimit: item.hit_limit)
        #expect(reply.cleaned == item.cleaned)
        #expect(reply.failure?.rawValue == item.failure)
    }

    @Test(arguments: (fixtures?.checks ?? []).map(\.name))
    func checks(name: String) throws {
        let prompt = try loadPrompt()
        let item = try #require(Self.fixtures?.checks.first { $0.name == name })
        let failures = HardChecks.check(
            transcript: item.transcript, cleaned: item.cleaned, vocabulary: item.vocabulary,
            maxWordsRatio: prompt.checks.maxOutputWordsRatio, maxWordsSlack: prompt.checks.maxOutputWordsSlack)
        #expect(failures == item.failures, "\(item.transcript) -> \(item.cleaned)")
    }

    @Test func caseNamesAreUnique() throws {
        let fixtures = try #require(Self.fixtures)
        #expect(Set(fixtures.checks.map(\.name)).count == fixtures.checks.count)
        #expect(Set(fixtures.replies.map(\.name)).count == fixtures.replies.count)
    }

    @Test func hugeNumbersDontTrap() {
        let digits = String(repeating: "9", count: 40)
        #expect(HardChecks.check(transcript: "use \(digits)", cleaned: "Use \(digits).").isEmpty)
        #expect(HardChecks.check(transcript: "use 007", cleaned: "Use 7.").isEmpty)
        let hundreds = Array(repeating: "hundred", count: 30).joined(separator: " ")
        _ = HardChecks.check(transcript: "nine \(hundreds)", cleaned: "x")
    }
}

struct ThoughtPieceFixtureTests {
    struct Case: Decodable {
        var name: String
        var text: String
        var max_words: Int?
        var pieces: [String]
    }

    struct File: Decodable { var cases: [Case] }

    static let cases: [Case] = (try? fixture("thought-pieces.json", File.self).cases) ?? []

    @Test func fixturesAreThere() {
        #expect(Self.cases.count >= 10)
        #expect(Set(Self.cases.map(\.name)).count == Self.cases.count)
    }

    @Test(arguments: cases.map(\.name))
    func splits(name: String) throws {
        let item = try #require(Self.cases.first { $0.name == name })
        let pieces = ThoughtPieces.split(item.text, maxWords: item.max_words ?? ThoughtPieces.maxWords)
        #expect(pieces == item.pieces)
    }
}

/// Details the shared fixtures can't carry (accepted replies with extra keys
/// would fail the label tool's teacher schema). cli/tests/test_hardchecks.py
/// has the same cases.
struct StrictJSONTests {
    @Test func keysCompareByCodePoints() {
        #expect(CleanupReply.parse("{\"cleaned\": \"a\", \"caf\u{e9}\": 1, \"cafe\u{301}\": 2}").cleaned == "a")
    }

    @Test func nestingUpTo100IsFine() {
        let deep = String(repeating: "[", count: 99) + String(repeating: "]", count: 99)
        #expect(CleanupReply.parse(#"{"cleaned": "a", "x": "# + deep + "}").cleaned == "a")
    }

    @Test func surrogatePairsJoin() {
        #expect(CleanupReply.parse(#"{"cleaned": "a😀"}"#).cleaned == "a\u{1F600}")
    }

    @Test func numbersOnlyNeedTheGrammar() {
        #expect(CleanupReply.parse(#"{"cleaned": "a", "n": 1e400, "m": -0.5E-3}"#).cleaned == "a")
        for bad in ["01", "1.", ".5", "1e", "-", "+1", "0x10"] {
            #expect(StrictJSON.parse(bad) == nil, "\(bad)")
        }
        #expect(StrictJSON.parse(" -0.0e+5 ") == .number)
    }
}
