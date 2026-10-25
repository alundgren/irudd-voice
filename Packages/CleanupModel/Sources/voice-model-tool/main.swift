import CleanupModel
import Foundation
import IruddVoiceKit
import MLX

// voice-model-tool: runs the cleanup model from the terminal, with the same
// Swift code the XPC helper uses. No windows, no mic, no XPC.
//
//   generate --model DIR [--inputs evals/parity.jsonl] --out FILE [--max-tokens 96]
//   compare  --reference FILE --swift FILE [--model DIR]
//   eval     --model DIR --set questions|transcripts [--out FILE]
//   bench    --model DIR [--runs 10] [--minutes N] [--out FILE]
//   prompt-check --model DIR --reference FILE   (prompt tokens only; no weights loaded)
//   xpc-check --model DIR    (the helper's handler over an in-process XPC listener)
//   thought-check [--models DIR] [--model-id ID]   (the app's cleanup path, see below)
//   draft-check [--model DIR]   (drafted vs plain tokens at 5 and 6 tokens, and both fallbacks)
//
// Common options: --prompt FILE (default shared/cleanup-prompt.json),
// --no-verify (skip manifest checksums). A model folder whose manifest names
// a drafter decodes speculatively, as in the app (docs/models/speculative.md).
// generate, eval and bench also take --draft-tokens N (replaces the
// manifest's count; 0 loads the drafter's model class without drafting),
// --draft DIR (another drafter folder) and --no-draft (one token at a time,
// ignoring the manifest).

let repoFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // voice-model-tool
    .deletingLastPathComponent()  // Sources
    .deletingLastPathComponent()  // CleanupModel
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()  // repo

struct ToolError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// `--name value` options and `--flag` switches.
struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ arguments: ArraySlice<String>) throws {
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            guard argument.hasPrefix("--") else { throw ToolError("unexpected argument \(argument)") }
            let name = String(argument.dropFirst(2))
            if ["no-verify", "no-draft"].contains(name) {
                flags.insert(name)
            } else {
                guard let value = rest.popFirst() else { throw ToolError("--\(name) needs a value") }
                values[name] = value
            }
        }
    }

    func url(_ name: String, default fallback: URL? = nil) throws -> URL {
        if let value = values[name] { return URL(fileURLWithPath: value) }
        if let fallback { return fallback }
        throw ToolError("--\(name) is required")
    }

    func int(_ name: String, default fallback: Int) throws -> Int {
        guard let value = values[name] else { return fallback }
        guard let number = Int(value) else { throw ToolError("--\(name) must be a whole number") }
        return number
    }

    func double(_ name: String, default fallback: Double) throws -> Double {
        guard let value = values[name] else { return fallback }
        guard let number = Double(value) else { throw ToolError("--\(name) must be a number") }
        return number
    }
}

/// One line of an evals/*.jsonl file.
struct InputItem: Codable {
    var id: String?
    var transcript: String
    var vocabulary: [String]?
    var expected: String?
}

func readJSONL(_ url: URL) throws -> [InputItem] {
    let text = try String(contentsOf: url, encoding: .utf8)
    return try text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map {
        try JSONDecoder().decode(InputItem.self, from: Data($0.utf8))
    }
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (encoder.encode(value) + Data("\n".utf8)).write(to: url)
}

func sha256(_ url: URL) throws -> String {
    try ModelManifest.sha256(of: url)
}

func log(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func footprint() -> (current: UInt64, peak: UInt64) { processFootprint() }

func gigabytes(_ bytes: UInt64) -> Double {
    (Double(bytes) / 1_073_741_824 * 100).rounded() / 100
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    // Nearest rank: p90 of 10 runs is the 9th fastest.
    let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
    return sorted[max(0, min(sorted.count - 1, rank - 1))]
}

func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

func drafter(_ options: Options) throws -> DrafterChoice {
    let count = try options.values["draft-tokens"].map { _ in try options.int("draft-tokens", default: 3) }
    if let count, count < 0 { throw ToolError("--draft-tokens must be 0 or more") }
    if options.flags.contains("no-draft") {
        guard options.values["draft"] == nil, count == nil else {
            throw ToolError("--no-draft can't be combined with --draft or --draft-tokens")
        }
        return .off
    }
    guard let folder = options.values["draft"] else { return .fromManifest(draftTokens: count) }
    return .folder(Drafter(folder: URL(fileURLWithPath: folder), draftTokens: count ?? 3))
}

/// " draft drafter x3" for runner labels, or "" without a drafter.
func drafterLabel(_ engine: CleanupEngine) async -> String {
    guard let drafter = await engine.drafter else { return "" }
    return " draft \(drafter.folder.lastPathComponent) x\(drafter.draftTokens)"
}

/// "drafted 120, accepted 96 (80%)" for a run with a drafter.
func draftSummary(drafted: Int, accepted: Int, stopped: String?) -> String {
    let rate = drafted > 0 ? Int((Double(accepted) / Double(drafted) * 100).rounded()) : 0
    return "drafted \(drafted), accepted \(accepted) (\(rate)%)" + (stopped.map { "; drafting stopped: \($0)" } ?? "")
}

func makeEngine(_ options: Options) throws -> CleanupEngine {
    let prompt = try CleanupPrompt.load(from: options.url("prompt", default: repoFolder.appendingPathComponent("shared/cleanup-prompt.json")))
    return CleanupEngine(prompt: prompt)
}

// ---- generate ------------------------------------------------------------------

/// Same layout as the Python `parity-reference` file (docs/models/parity-format.md).
struct ParityFile: Codable {
    struct Item: Codable {
        var id: String
        var transcript: String
        var vocabulary: [String]
        var prompt: String
        var prompt_token_ids: [Int]
        var generated_token_ids: [Int]
        var stop_token_id: Int?
        var text: String
    }

    var format: Int
    var model_id: String
    var manifest_sha256: String
    var prompt_version: String
    var inputs_sha256: String
    var chat_template_options: [String: TemplateOption]
    var max_new_tokens: Int
    var stop_token_ids: [Int]
    var runner: String?
    var items: [Item]
}

func generate(_ options: Options) async throws {
    let folder = try options.url("model")
    let inputs = try options.url("inputs", default: repoFolder.appendingPathComponent("evals/parity.jsonl"))
    let out = try options.url("out")
    let maxTokens = try options.int("max-tokens", default: 96)
    let engine = try makeEngine(options)
    try await engine.load(folder: folder, verify: !options.flags.contains("no-verify"), drafter: drafter(options))
    let prompt = engine.prompt
    var items: [ParityFile.Item] = []
    for (index, item) in try readJSONL(inputs).enumerated() {
        let terms = prompt.usedTerms(item.vocabulary ?? [])
        let messages = prompt.messages(transcript: item.transcript, terms: terms)
        let result = try await engine.generate(messages: messages, maxTokens: maxTokens)
        let id = item.id ?? String(index + 1)
        log("\(id): \(result.promptTokens.count) prompt tokens, \(result.tokens.count) generated, "
            + String(format: "%.2f s", result.promptSeconds + result.generateSeconds)
            + (result.draftedTokens > 0 || result.draftingStopped != nil
                ? ", " + draftSummary(drafted: result.draftedTokens, accepted: result.acceptedTokens,
                                      stopped: result.draftingStopped) : ""))
        items.append(.init(
            id: id, transcript: item.transcript, vocabulary: item.vocabulary ?? [],
            prompt: try await engine.decode(result.promptTokens),
            prompt_token_ids: result.promptTokens, generated_token_ids: result.tokens,
            stop_token_id: result.stopToken, text: result.text))
    }
    let manifest = try require(await engine.manifest)
    try writeJSON(ParityFile(
        format: 1, model_id: manifest.id,
        manifest_sha256: try sha256(folder.appendingPathComponent(ModelManifest.fileName)),
        prompt_version: prompt.version, inputs_sha256: try sha256(inputs),
        chat_template_options: prompt.chatTemplateOptions, max_new_tokens: maxTokens,
        stop_token_ids: await engine.stopTokens.sorted(),
        runner: "mlx-swift-lm 3.32.3" + (await drafterLabel(engine)),
        items: items), to: out)
    log("wrote \(out.path)")
}

func require<T>(_ value: T?) throws -> T {
    guard let value else { throw ToolError("missing value") }
    return value
}

// ---- compare -------------------------------------------------------------------

/// Compares a Swift `generate` file with a Python reference. Prints OK, or the
/// first differing token (prompt first, then generated) with both IDs and
/// their decoded text. Exits 1 on any difference.
func compare(_ options: Options) async throws -> Bool {
    let reference = try JSONDecoder().decode(ParityFile.self, from: Data(contentsOf: options.url("reference")))
    let swift = try JSONDecoder().decode(ParityFile.self, from: Data(contentsOf: options.url("swift")))
    var tokenizer: TokenText?
    if let model = options.values["model"] {
        tokenizer = try await TokenText(folder: URL(fileURLWithPath: model))
    }
    func show(_ id: Int?) -> String {
        guard let id else { return "(none)" }
        guard let tokenizer else { return "\(id)" }
        return "\(id) \(String(reflecting: tokenizer.text([id])))"
    }
    var ok = true
    if reference.manifest_sha256 != swift.manifest_sha256 {
        print("manifest differs: the files are from different model folders")
        ok = false
    }
    if reference.inputs_sha256 != swift.inputs_sha256 || reference.max_new_tokens != swift.max_new_tokens {
        print("inputs or max_new_tokens differ")
        ok = false
    }
    if reference.stop_token_ids != swift.stop_token_ids {
        print("stop tokens differ: python \(reference.stop_token_ids), swift \(swift.stop_token_ids)")
        ok = false
    }
    let swiftItems = Dictionary(swift.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var identical = 0
    for item in reference.items {
        guard let other = swiftItems[item.id] else {
            print("\(item.id): missing from the Swift file")
            ok = false
            continue
        }
        for (label, a, b) in [("prompt", item.prompt_token_ids, other.prompt_token_ids),
                              ("generated", item.generated_token_ids, other.generated_token_ids)] {
            guard a != b else { continue }
            let index = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
            let pythonID = index < a.count ? a[index] : nil
            let swiftID = index < b.count ? b[index] : nil
            print("\(item.id): \(label) tokens differ at index \(index): python \(show(pythonID)), swift \(show(swiftID))")
            if label == "generated" {
                print("  python text: \(String(reflecting: item.text))")
                print("  swift text:  \(String(reflecting: other.text))")
            }
            ok = false
            break
        }
        if item.prompt_token_ids == other.prompt_token_ids && item.generated_token_ids == other.generated_token_ids {
            if item.stop_token_id == other.stop_token_id {
                identical += 1
            } else {
                print("\(item.id): stop token differs: python \(show(item.stop_token_id)), swift \(show(other.stop_token_id))")
                ok = false
            }
        }
    }
    print(ok ? "OK: \(reference.items.count) inputs, identical tokens (\(reference.model_id))"
        : "MISMATCH: \(identical) of \(reference.items.count) inputs identical (\(reference.model_id))")
    return ok
}

/// Builds every reference item's prompt with the Swift prompt builder and
/// tokenizer and compares the token IDs. Loads only the tokenizer.
func promptCheck(_ options: Options) async throws -> Bool {
    let reference = try JSONDecoder().decode(ParityFile.self, from: Data(contentsOf: options.url("reference")))
    let prompt = try CleanupPrompt.load(from: options.url("prompt", default: repoFolder.appendingPathComponent("shared/cleanup-prompt.json")))
    let tokenizer = try await TokenText(folder: options.url("model"))
    var ok = true
    for item in reference.items {
        let ids = try tokenizer.promptTokens(prompt.messages(transcript: item.transcript, terms: prompt.usedTerms(item.vocabulary)), prompt: prompt)
        guard ids != item.prompt_token_ids else { continue }
        ok = false
        let index = zip(ids, item.prompt_token_ids).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            ?? min(ids.count, item.prompt_token_ids.count)
        let python = index < item.prompt_token_ids.count ? item.prompt_token_ids[index] : nil
        let swift = index < ids.count ? ids[index] : nil
        print("\(item.id): prompt differs at token \(index): python \(python.map { "\($0) \(String(reflecting: tokenizer.text([$0])))" } ?? "(end)"), "
            + "swift \(swift.map { "\($0) \(String(reflecting: tokenizer.text([$0])))" } ?? "(end)")")
        print("  python: \(String(reflecting: String(tokenizer.text(Array(item.prompt_token_ids[max(0, index - 8)...])).prefix(160))))")
        print("  swift:  \(String(reflecting: String(tokenizer.text(Array(ids[max(0, index - 8)...])).prefix(160))))")
    }
    print(ok ? "OK: \(reference.items.count) prompts identical" : "MISMATCH")
    return ok
}

// ---- eval ----------------------------------------------------------------------

struct EvalReport: Codable {
    struct Item: Codable {
        var id: String
        var transcript: String
        var reply: String
        var cleaned: String?
        var failure: String?
        var checks: [String]
        var expected: String?
        var matchesExpected: Bool?
        var seconds: Double
    }

    var model_id: String
    var set: String
    var prompt_version: String
    var runner: String
    var items_total: Int
    var items_failed: Int
    var reply_failures: [String: Int]
    var check_failures: [String: Int]
    var exact_matches: Int?
    var items: [Item]
}

/// Cleans every transcript in evals/<set>.jsonl through the Swift prompt,
/// parser and hard checks. An item fails when the reply can't be read or
/// any hard check fails.
func evaluate(_ options: Options) async throws -> Bool {
    let folder = try options.url("model")
    guard let set = options.values["set"], ["questions", "transcripts"].contains(set) else {
        throw ToolError("--set must be questions or transcripts")
    }
    let inputs = try options.url("inputs", default: repoFolder.appendingPathComponent("evals/\(set).jsonl"))
    let engine = try makeEngine(options)
    try await engine.load(folder: folder, verify: !options.flags.contains("no-verify"), drafter: drafter(options))
    let prompt = engine.prompt
    var items: [EvalReport.Item] = []
    var replyFailures: [String: Int] = [:]
    var checkFailures: [String: Int] = [:]
    var drafted = 0, accepted = 0
    var stopped: String?
    for (index, input) in try readJSONL(inputs).enumerated() {
        let id = input.id ?? String(index + 1)
        let terms = prompt.usedTerms(input.vocabulary ?? [])
        let result = try await engine.clean(transcript: input.transcript, vocabulary: terms)
        drafted += result.draftedTokens
        accepted += result.acceptedTokens
        stopped = stopped ?? result.draftingStopped
        let reply = CleanupReply.parse(result.text, hitLimit: result.hitLimit, key: prompt.outputKey)
        var checks: [String] = []
        if let cleaned = reply.cleaned {
            checks = HardChecks.check(
                transcript: input.transcript, cleaned: cleaned, vocabulary: terms,
                maxWordsRatio: prompt.checks.maxOutputWordsRatio, maxWordsSlack: prompt.checks.maxOutputWordsSlack)
        }
        if let failure = reply.failure { replyFailures[failure.rawValue, default: 0] += 1 }
        for check in checks { checkFailures[check, default: 0] += 1 }
        let failed = reply.failure != nil || !checks.isEmpty
        log("\(id): \(failed ? "FAIL \(reply.failure?.rawValue ?? checks.joined(separator: ","))" : "ok") "
            + "\(String(reflecting: reply.cleaned ?? result.text))")
        items.append(.init(
            id: id, transcript: input.transcript, reply: result.text, cleaned: reply.cleaned,
            failure: reply.failure?.rawValue, checks: checks, expected: input.expected,
            matchesExpected: input.expected.map { $0 == reply.cleaned },
            seconds: round3(result.promptSeconds + result.generateSeconds)))
    }
    let failed = items.filter { $0.failure != nil || !$0.checks.isEmpty }.count
    let exact = items.contains { $0.expected != nil } ? items.filter { $0.matchesExpected == true }.count : nil
    let manifest = try require(await engine.manifest)
    let report = EvalReport(
        model_id: manifest.id, set: set, prompt_version: prompt.version,
        runner: "swift (mlx-swift-lm 3.32.3)" + (await drafterLabel(engine)),
        items_total: items.count, items_failed: failed, reply_failures: replyFailures,
        check_failures: checkFailures, exact_matches: exact, items: items)
    if let out = options.values["out"] {
        try writeJSON(report, to: URL(fileURLWithPath: out))
    }
    print("\(manifest.id) \(set): \(items.count - failed)/\(items.count) passed, \(failed) failed"
        + (exact.map { ", \($0) exact matches" } ?? "")
        + (replyFailures.isEmpty ? "" : ", reply failures \(replyFailures)")
        + (checkFailures.isEmpty ? "" : ", check failures \(checkFailures)")
        + (await engine.drafter == nil ? "" : "; " + draftSummary(drafted: drafted, accepted: accepted, stopped: stopped)))
    return failed == 0
}

// ---- bench ---------------------------------------------------------------------

struct BenchReport: Codable {
    struct Soak: Codable {
        var minutes: Double
        var cleanups: Int
        var p50_seconds: Double
        var p90_seconds: Double
        var slowest_seconds: Double
        var slowest_last_minute_seconds: Double
        var footprint_end_gb: Double
    }

    var model_id: String
    var runner: String
    var cold_verify_seconds: Double
    var cold_load_seconds: Double
    var cold_warmup_seconds: Double
    var warm_runs: [Double]
    var warm_p50_seconds: Double
    var warm_p90_seconds: Double
    var runs_within_2s: Int
    var generated_tokens: [Int]
    var peak_footprint_gb: Double
    var mlx_peak_gb: Double
    var soak: Soak?
    var drafter: String?
    var draft_tokens: Int?
    var drafted_tokens: Int?
    var accepted_tokens: Int?
    var drafting_stopped: String?
}

/// One cleanup the way the app will run it: generate, parse, hard checks.
/// Returns the wall-clock seconds and the generation result.
func timedCleanup(_ engine: CleanupEngine, _ transcript: String) async throws -> (Double, GenerationResult) {
    let clock = ContinuousClock()
    let start = clock.now
    let result = try await engine.clean(transcript: transcript)
    let prompt = engine.prompt
    let reply = CleanupReply.parse(result.text, hitLimit: result.hitLimit, key: prompt.outputKey)
    if let cleaned = reply.cleaned {
        _ = HardChecks.check(transcript: transcript, cleaned: cleaned)
    }
    return ((clock.now - start).seconds, result)
}

func bench(_ options: Options) async throws {
    let folder = try options.url("model")
    let runs = try options.int("runs", default: 10)
    let minutes = try options.double("minutes", default: 0)
    let inputs = try readJSONL(try options.url("inputs", default: repoFolder.appendingPathComponent("evals/bench.jsonl")))
    guard !inputs.isEmpty else { throw ToolError("no bench inputs") }
    let engine = try makeEngine(options)
    let cold = try await engine.load(folder: folder, verify: !options.flags.contains("no-verify"),
                                     drafter: drafter(options))
    let draft = await engine.drafter
    log(String(format: "cold: verify %.2f s, load %.2f s, warm-up %.2f s", cold.verifySeconds, cold.loadSeconds, cold.warmupSeconds))

    var warm: [Double] = []
    var tokens: [Int] = []
    var drafted = 0, accepted = 0
    var stopped: String?
    for run in 0..<runs {
        let (seconds, result) = try await timedCleanup(engine, inputs[run % inputs.count].transcript)
        warm.append(round3(seconds))
        tokens.append(result.tokens.count)
        drafted += result.draftedTokens
        accepted += result.acceptedTokens
        stopped = stopped ?? result.draftingStopped
        log(String(format: "run %d: %.3f s, %d tokens", run + 1, seconds, result.tokens.count)
            + (draft == nil ? "" : ", " + draftSummary(drafted: result.draftedTokens, accepted: result.acceptedTokens,
                                                       stopped: result.draftingStopped)))
    }

    var soak: BenchReport.Soak?
    if minutes > 0 {
        let clock = ContinuousClock()
        let start = clock.now
        let end = start + .seconds(minutes * 60)
        var times: [Double] = []
        var lastMinute: [Double] = []
        var index = 0
        while clock.now < end {
            let (seconds, _) = try await timedCleanup(engine, inputs[index % inputs.count].transcript)
            index += 1
            times.append(seconds)
            if end - clock.now < .seconds(60) { lastMinute.append(seconds) }
            if index % 25 == 0 {
                log(String(format: "soak: %d cleanups, %.1f min, footprint %.2f GB", index,
                           (clock.now - start).seconds / 60, gigabytes(footprint().current)))
            }
        }
        soak = .init(
            minutes: round3((clock.now - start).seconds / 60), cleanups: times.count,
            p50_seconds: round3(percentile(times, 50)), p90_seconds: round3(percentile(times, 90)),
            slowest_seconds: round3(times.max() ?? 0), slowest_last_minute_seconds: round3(lastMinute.max() ?? 0),
            footprint_end_gb: gigabytes(footprint().current))
    }

    let manifest = try require(await engine.manifest)
    let report = BenchReport(
        model_id: manifest.id, runner: "swift (mlx-swift-lm 3.32.3)",
        cold_verify_seconds: round3(cold.verifySeconds), cold_load_seconds: round3(cold.loadSeconds),
        cold_warmup_seconds: round3(cold.warmupSeconds), warm_runs: warm,
        warm_p50_seconds: round3(percentile(warm, 50)), warm_p90_seconds: round3(percentile(warm, 90)),
        runs_within_2s: warm.filter { $0 <= 2 }.count, generated_tokens: tokens,
        peak_footprint_gb: gigabytes(footprint().peak), mlx_peak_gb: gigabytes(UInt64(Memory.peakMemory)),
        soak: soak, drafter: draft?.folder.lastPathComponent, draft_tokens: draft?.draftTokens,
        drafted_tokens: draft.map { _ in drafted }, accepted_tokens: draft.map { _ in accepted },
        drafting_stopped: stopped)
    if let out = options.values["out"] {
        try writeJSON(report, to: URL(fileURLWithPath: out))
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(report), as: UTF8.self))
}

// ---- xpc-check -----------------------------------------------------------------

/// Runs the XPC helper's handler behind an anonymous in-process listener and
/// drives it with `CleanupClient`, the way the app will: status, load, clean,
/// unload. Exercises the real service code without launching anything.
final class ListenerHost: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let handler: CleanupServiceHandler

    init(handler: CleanupServiceHandler) {
        self.handler = handler
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

func xpcCheck(_ options: Options) async throws -> Bool {
    let folder = try options.url("model")
    let verify = !options.flags.contains("no-verify")
    let prompt = try CleanupPrompt.load(from: options.url("prompt", default: repoFolder.appendingPathComponent("shared/cleanup-prompt.json")))
    let engine = CleanupEngine(prompt: prompt)
    let host = ListenerHost(handler: CleanupServiceHandler(prompt: prompt, backend: engine))
    let client = CleanupClient(endpoint: host.listener.endpoint)
    var ok = true
    func expect(_ condition: Bool, _ label: String) {
        print("\(condition ? "ok  " : "FAIL") \(label)")
        ok = ok && condition
    }
    expect(try await client.status().state == .empty, "starts empty")
    let loaded = try await client.load(LoadRequest(folder: folder.path, verify: verify))
    expect(loaded.status.state == .ready, "loads \(loaded.status.modelID ?? loaded.error ?? "?") in "
        + String(format: "%.2f s", loaded.loadSeconds ?? 0))
    let transcript = "um can you check why the build fails on port eight zero eight zero"
    let response = try await client.clean(CleanRequest(transcript: transcript, vocabulary: ["SwiftUI"]))
    let reply = CleanupReply.parse(response.reply ?? "", hitLimit: response.hitLimit, key: prompt.outputKey)
    if try ModelManifest.load(folder: folder).drafter != nil {
        let problem = await draftingProblem(engine, status: loaded.status, responses: [response])
        expect(problem == nil, "drafts with the manifest's drafter: "
               + (problem ?? "\(response.draftedTokens ?? 0) tokens drafted"))
    }
    expect(response.error == nil && response.generatedTokens > 0,
           "cleans: \(String(reflecting: reply.cleaned ?? response.reply ?? response.error ?? "")) "
           + String(format: "(%.2f s)", response.promptSeconds + response.generateSeconds))

    // A 768-token reply would take several seconds; the deadline stops it.
    let clock = ContinuousClock()
    var start = clock.now
    let late = try await client.clean(CleanRequest(transcript: String(repeating: "and then the next step ", count: 60),
                                                   deadlineSeconds: 0.3))
    let lateTime = (clock.now - start).seconds
    start = clock.now
    let next = try await client.clean(CleanRequest(transcript: transcript))
    expect(late.timedOut && late.reply == nil && lateTime < 1.5,
           String(format: "stops at its deadline (0.3 s deadline, answered in %.2f s, %d tokens)", lateTime, late.generatedTokens))
    expect(next.error == nil && (clock.now - start).seconds < 3,
           String(format: "the next cleanup isn't held up (%.2f s)", (clock.now - start).seconds))

    let status = try await client.status()
    expect(status.state == .ready && (status.residentBytes ?? 0) > 0,
           String(format: "status ready, %.2f GB resident", gigabytes(status.residentBytes ?? 0)))
    expect(try await client.unload().state == .empty, "unloads")
    let refused = try await client.clean(CleanRequest(transcript: "x"))
    expect(refused.reply == nil && refused.error != nil, "refuses to clean when unloaded")

    // Unload while a load is still running: nothing may stay loaded.
    async let racing = client.load(LoadRequest(folder: folder.path, verify: verify))
    try await Task.sleep(for: .milliseconds(150))
    let unloaded = try await client.unload()
    // The unload replies only once the racing load has let go of its weights.
    let inFlightAtReply = await engine.loadsInFlight
    let raced = try await racing
    let engineLoaded = await engine.isLoaded
    let after = try await client.status().state
    expect(unloaded.state == .empty && raced.error != nil && !engineLoaded && after == .empty && inFlightAtReply == 0,
           "unload during a load waits for it and leaves nothing loaded (load said: \(raced.error ?? "ready"))")

    let bad = try await client.load(LoadRequest(modelID: "../voice"))
    expect(bad.error != nil && bad.status.state == .empty, "refuses a bad model id and changes nothing")
    return ok
}

// ---- thought-check -------------------------------------------------------------

/// Why a folder whose manifest names a drafter isn't really drafting, or nil:
/// the engine has no drafter, the helper reported a problem, or a cleanup
/// drafted nothing or stopped drafting.
func draftingProblem(_ engine: CleanupEngine, status: CleanupStatus?, responses: [CleanResponse]) async -> String? {
    if await engine.drafter == nil {
        return "no drafter loaded (\(await engine.drafterProblem ?? status?.drafterProblem ?? "no reason given"))"
    }
    if let problem = status?.drafterProblem { return problem }
    if let problem = responses.lazy.compactMap(\.drafterProblem).first { return problem }
    if responses.reduce(0, { $0 + ($1.draftedTokens ?? 0) }) == 0 { return "no tokens were drafted" }
    return nil
}

/// Times every clean call that passes through it, and keeps the replies.
final class TimingHelper: CleanupHelper, @unchecked Sendable {
    let inner: CleanupClient
    private let lock = NSLock()
    private var times: [(words: Int, seconds: Double)] = []
    private var replies: [CleanResponse] = []

    init(_ inner: CleanupClient) { self.inner = inner }

    var pieces: [(words: Int, seconds: Double)] { lock.withLock { times } }
    var responses: [CleanResponse] { lock.withLock { replies } }
    func reset() { lock.withLock { times = [] } }

    func status(timeout: Duration) async throws -> CleanupStatus { try await inner.status(timeout: timeout) }
    func load(_ request: LoadRequest, timeout: Duration) async throws -> LoadResponse {
        try await inner.load(request, timeout: timeout)
    }
    func unload(timeout: Duration) async throws -> CleanupStatus { try await inner.unload(timeout: timeout) }
    func clean(_ request: CleanRequest, timeout: Duration?) async throws -> CleanResponse {
        let start = ContinuousClock.now
        defer {
            let seconds = (ContinuousClock.now - start).seconds
            lock.withLock { times.append((request.transcript.split(separator: " ").count, seconds)) }
        }
        let response = try await inner.clean(request, timeout: timeout)
        lock.withLock { replies.append(response) }
        return response
    }
}

/// The app's cleanup path on a real model, without the app: the helper's
/// handler over an in-process XPC listener, `CleanupClient`, and
/// `CleanupCoordinator` on a temp database (the real models folder is only
/// read). Checks the e2e sentence, the 40 questions, a 458-word thought in
/// pieces, the training lease, and the row fields.
func thoughtCheck(_ options: Options) async throws -> Bool {
    let models = try options.url("models", default: ModelPaths.modelsFolder)
    let modelID = options.values["model-id"] ?? CleanupDefaults.modelID
    let prompt = try CleanupPrompt.load(from: options.url("prompt", default: repoFolder.appendingPathComponent("shared/cleanup-prompt.json")))
    let engine = CleanupEngine(prompt: prompt)
    let host = ListenerHost(handler: CleanupServiceHandler(prompt: prompt, backend: engine, modelsFolder: models))
    let helper = TimingHelper(CleanupClient(endpoint: host.listener.endpoint))
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("thought-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try ChunkStore(path: temp.appendingPathComponent("voice.sqlite").path)
    let coordinator = CleanupCoordinator(
        helper: helper, store: store, prompt: prompt, modelsFolder: models,
        vocabularyFile: temp.appendingPathComponent("vocabulary.json"), defaultModelID: modelID)
    var ok = true
    func expect(_ condition: Bool, _ label: String) {
        print("\(condition ? "ok  " : "FAIL") \(label)")
        ok = ok && condition
    }

    let clock = ContinuousClock()
    var start = clock.now
    await coordinator.idleCheck(busy: false)
    let firstStatus = try await store.appState("cleanup.status")
    let firstLoaded = try await store.appState("cleanup.loaded_model")
    expect(firstStatus == "loaded" && firstLoaded == modelID,
           String(format: "loads %@ with checksums in %.1f s (%@)", modelID, (clock.now - start).seconds,
                  firstStatus ?? "no status"))

    // The e2e sentence (plan check e2e).
    let sentence = "um change the timeout to fifteen seconds no fifty seconds and don't touch the retries"
    let expected = "Change the timeout to fifty seconds, and don't touch the retries."
    let e2e = await coordinator.clean(sentence)
    let safe = e2e.outcome == .cleaned || e2e.pasteText == sentence
    expect(safe, "e2e: \(e2e.outcome.rawValue) in \(e2e.milliseconds) ms, pastes \(String(reflecting: e2e.pasteText))")
    print("     \(e2e.pasteText == expected ? "matches" : "differs from") the expected \(String(reflecting: expected))")
    if e2e.outcome != .cleaned { print("     why: \(e2e.detail)") }

    // The 40 questions and commands through the app's path (plan check
    // never-answers): what would be pasted is the cleaned request, or the
    // raw text when the model's reply failed a check; never an answer.
    var outcomes: [String: Int] = [:]
    var unsafe: [String] = []
    for item in try readJSONL(repoFolder.appendingPathComponent("evals/questions.jsonl")) {
        let result = await coordinator.clean(item.transcript)
        outcomes[result.outcome.rawValue, default: 0] += 1
        let pastedFails = !HardChecks.check(transcript: item.transcript, cleaned: result.pasteText,
                                            maxWordsRatio: prompt.checks.maxOutputWordsRatio,
                                            maxWordsSlack: prompt.checks.maxOutputWordsSlack).isEmpty
        if result.outcome == .cleaned && pastedFails || result.outcome != .cleaned && result.pasteText != item.transcript {
            unsafe.append(item.id ?? item.transcript)
        }
    }
    expect(unsafe.isEmpty, "40 questions: \(outcomes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))"
           + (unsafe.isEmpty ? "; every paste is the request itself" : "; unsafe: \(unsafe)"))

    // A 458-word thought: pieces of at most 120 words, each within the deadline.
    let long = try String(contentsOf: repoFolder.appendingPathComponent("evals/long-thought.txt"), encoding: .utf8)
    helper.reset()
    let result = await coordinator.clean(long)
    let pieces = helper.pieces
    let slowest = pieces.map(\.seconds).max() ?? 0
    expect(pieces.allSatisfy { $0.words <= ThoughtPieces.maxWords } && slowest < prompt.generation.timeoutSeconds,
           "long thought: \(long.split(separator: " ").count) words, \(result.pieces) pieces, "
           + pieces.map { String(format: "%d words %.2f s", $0.words, $0.seconds) }.joined(separator: ", "))
    expect(result.outcome == .cleaned || result.pasteText == long,
           "long thought: \(result.outcome.rawValue) in \(result.milliseconds) ms, pasted once (\(result.pasteText.split(separator: " ").count) words)")
    if result.outcome != .cleaned { print("     why: \(result.detail)") }
    if result.outcome == .cleaned { print("     cleaned: \(result.pasteText)") }

    // The training lease: unload, raw meanwhile, reload when it ends.
    try await store.setAppState("cleanup.unload_until", Timestamps.string(Date().addingTimeInterval(120)))
    start = clock.now
    await coordinator.idleCheck(busy: false)
    let unloadTime = (clock.now - start).seconds
    let loadedDuringLease = await engine.isLoaded
    let inFlight = await engine.loadsInFlight
    let leaseStatus = try await store.appState("cleanup.status")
    expect(leaseStatus == "unloaded-for-training" && !loadedDuringLease && inFlight == 0,
           String(format: "lease: unloaded in %.2f s, status %@", unloadTime, leaseStatus ?? "none"))
    let duringLease = await coordinator.clean("run the tests")
    expect(duringLease.outcome == .unloadedForTraining && duringLease.pasteText == "run the tests",
           "lease: a thought pastes raw (\(duringLease.outcome.rawValue))")
    try await store.deleteAppState("cleanup.unload_until")
    start = clock.now
    await coordinator.idleCheck(busy: false)
    let reloaded = await engine.isLoaded
    let reloadStatus = try await store.appState("cleanup.status")
    expect(reloaded && reloadStatus == "loaded",
           String(format: "lease ended: reloaded in %.1f s (no second checksum pass)", (clock.now - start).seconds))

    // The row fields.
    let audio = AudioEncoding.encode(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000)
    let now = Date()
    let meta = ChunkMeta(startedAt: now, signalAt: now, endedAt: now, startReason: .hotkey, endReason: .hotkey,
                         micUID: "thought-check", appVersion: "thought-check")
    let id = try await store.insertPending(meta: meta, audio: audio, durationMs: 1000)
    try await store.markCleanup(id: id, e2e.record)
    let row = try await store.cleanupRecord(id: id)
    expect(row == e2e.record && row?.promptVersion == prompt.version && row?.modelID == modelID,
           "row: cleanup_status \(row?.status ?? "-"), cleanup_model_id \(row?.modelID ?? "-"), "
           + "cleanup_ms \(row?.milliseconds ?? 0), prompt_version \(row?.promptVersion ?? "-")")

    // A model whose manifest names a drafter must really draft: a drafter
    // that silently fell back would only show up as slower cleanups.
    if let folder = ModelPaths.folder(forModel: modelID, in: models), try ModelManifest.load(folder: folder).drafter != nil {
        let status = try await helper.status(timeout: .seconds(5))
        let responses = helper.responses
        let problem = await draftingProblem(engine, status: status, responses: responses)
        let drafted = responses.reduce(0) { $0 + ($1.draftedTokens ?? 0) }
        let accepted = responses.reduce(0) { $0 + ($1.acceptedTokens ?? 0) }
        expect(problem == nil, "drafts with the manifest's drafter: " + (problem ?? draftSummary(
            drafted: drafted, accepted: accepted, stopped: nil) + " over \(responses.count) cleanups"))
    }
    return ok
}

// ---- draft-check ---------------------------------------------------------------

/// Speculative decoding on a folder whose manifest names a drafter, against
/// plain decoding (`--no-draft`, the app's path before drafters) on the 20
/// parity inputs at 5 and 6 tokens: the tokens, stop token and hit_limit must
/// be identical, and the drafter must really draft. Then both fallbacks: a
/// drafter that can't start (`setFailDraftStart`) and a drafter folder that
/// doesn't load (a copy of the folder, made of links, with a broken
/// drafter/config.json) must still give the plain tokens and report why.
func draftCheck(_ options: Options) async throws -> Bool {
    let folder = try options.url("model", default: ModelPaths.modelsFolder.appendingPathComponent(CleanupDefaults.modelID))
    let engine = try makeEngine(options)
    let inputs = try readJSONL(try options.url("inputs", default: repoFolder.appendingPathComponent("evals/parity.jsonl")))
    let prompt = engine.prompt
    var ok = true
    func expect(_ condition: Bool, _ label: String) {
        print("\(condition ? "ok  " : "FAIL") \(label)")
        ok = ok && condition
    }
    struct Run: Equatable { var tokens: [Int]; var stop: Int?; var hitLimit: Bool }
    func runAll(_ limit: Int) async throws -> (runs: [Run], drafted: Int, problems: [String]) {
        var runs: [Run] = [], drafted = 0, problems: [String] = []
        for item in inputs {
            let result = try await engine.generate(
                messages: prompt.messages(transcript: item.transcript, terms: prompt.usedTerms(item.vocabulary ?? [])),
                maxTokens: limit)
            runs.append(Run(tokens: result.tokens, stop: result.stopToken, hitLimit: result.hitLimit))
            drafted += result.draftedTokens
            if let problem = result.draftingStopped { problems.append(problem) }
        }
        return (runs, drafted, problems)
    }
    let limits = [5, 6]

    try await engine.load(folder: folder, verify: !options.flags.contains("no-verify"))
    expect(await engine.drafter != nil, "loads with its drafter"
        + ((await engine.drafterProblem).map { " (\($0))" } ?? ""))
    var drafted: [Int: [Run]] = [:]
    for limit in limits {
        let run = try await runAll(limit)
        drafted[limit] = run.runs
        expect(run.drafted > 0 && run.problems.isEmpty,
               "\(limit) tokens: drafted \(run.drafted) tokens" + (run.problems.first.map { "; \($0)" } ?? ""))
    }
    await engine.setFailDraftStart(true)
    let failedStart = try await runAll(6)
    await engine.setFailDraftStart(false)

    try await engine.load(folder: folder, verify: false, drafter: .off)
    for limit in limits {
        let plain = try await runAll(limit).runs
        let same = zip(plain, drafted[limit] ?? []).filter { $0 == $1 }.count
        expect(same == inputs.count && plain.allSatisfy { $0.tokens.count == limit ? $0.hitLimit : true },
               "\(limit) tokens: drafted and plain identical on \(same) of \(inputs.count) inputs")
        if limit == 6 {
            let fallbackSame = zip(plain, failedStart.runs).filter { $0 == $1 }.count
            expect(fallbackSame == inputs.count && failedStart.drafted == 0
                   && failedStart.problems.count == inputs.count
                   && failedStart.problems.allSatisfy { $0.hasPrefix("drafting couldn't start") },
                   "a drafter that can't start: plain tokens on \(fallbackSame) of \(inputs.count), reason given")
        }
    }

    // A drafter folder that doesn't load: links to every file but a broken
    // drafter config.
    let copy = FileManager.default.temporaryDirectory.appendingPathComponent("draft-check-\(UUID().uuidString)")
        .appendingPathComponent(folder.lastPathComponent)
    defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
    let manifest = try ModelManifest.load(folder: folder)
    for name in manifest.files.keys.sorted() + [ModelManifest.fileName] {
        let target = copy.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let drafterFolder = manifest.drafter?.folder, name == "\(drafterFolder)/config.json" {
            try Data("{ broken".utf8).write(to: target)
        } else {
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: folder.appendingPathComponent(name))
        }
    }
    try await engine.load(folder: copy, verify: false)
    let problem = await engine.drafterProblem
    expect(await engine.drafter == nil && problem != nil,
           "a drafter that doesn't load: loads without it (\(problem ?? "no reason given"))")
    let fallbackLoad = try await runAll(6)
    let plain6 = drafted[6] ?? []
    let loadSame = zip(fallbackLoad.runs, plain6).filter { $0 == $1 }.count
    expect(loadSame == inputs.count, "a drafter that doesn't load: same tokens on \(loadSame) of \(inputs.count)")
    return ok
}

// ---- main ----------------------------------------------------------------------

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    log("usage: voice-model-tool generate|compare|eval|bench [options]")
    exit(2)
}
do {
    let options = try Options(arguments.dropFirst(2))
    switch arguments[1] {
    case "generate": try await generate(options)
    case "compare": exit(try await compare(options) ? 0 : 1)
    case "eval": exit(try await evaluate(options) ? 0 : 1)
    case "bench": try await bench(options)
    case "prompt-check": exit(try await promptCheck(options) ? 0 : 1)
    case "xpc-check": exit(try await xpcCheck(options) ? 0 : 1)
    case "thought-check": exit(try await thoughtCheck(options) ? 0 : 1)
    case "draft-check": exit(try await draftCheck(options) ? 0 : 1)
    default:
        log("unknown command \(arguments[1])")
        exit(2)
    }
} catch {
    log("error: \(error)")
    exit(1)
}
