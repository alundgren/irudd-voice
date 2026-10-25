import Foundation
import IruddVoiceKit
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

/// One greedy generation: the token IDs and how it went.
public struct GenerationResult: Sendable {
    /// The prompt after the chat template, as token IDs.
    public var promptTokens: [Int]
    /// The generated token IDs, without the end-of-turn token.
    public var tokens: [Int]
    /// The generated text (special tokens kept, so thinking tags show up).
    public var text: String
    /// The token that ended generation, or nil when it stopped at the limit
    /// or the deadline.
    public var stopToken: Int?
    /// Stopped at the deadline; `tokens` and `text` are unfinished.
    public var timedOut: Bool
    /// Stopped at `max_tokens` rather than an end-of-turn token.
    public var hitLimit: Bool { stopToken == nil && !timedOut }
    public var promptSeconds: Double
    public var generateSeconds: Double
    /// With a drafter: tokens it proposed and how many the model accepted.
    public var draftedTokens = 0
    public var acceptedTokens = 0
    /// With a drafter: why the iterator went back to one token at a time,
    /// or nil when it kept drafting.
    public var draftingStopped: String?
}

/// A drafter for speculative decoding (docs/models/speculative.md): a small
/// model that guesses the next few tokens, which the cleanup model then
/// checks in one forward pass. Greedy checking keeps the tokens the model
/// would have picked itself.
public struct Drafter: Sendable, Equatable {
    /// A drafter folder: Gemma 4's assistant (model_type gemma4_assistant,
    /// the `drafter/` folder a manifest names) or Qwen3.5's own multi-token
    /// head (model_type qwen3_5, `mtp.*` weights; see scripts/make-drafter.py).
    public var folder: URL
    /// Tokens drafted per round. mlx-swift-lm caps Qwen3.5's head at 1.
    /// 0 loads the model the way the drafter needs it but generates one
    /// token at a time, which tells the model class apart from drafting
    /// when outputs differ.
    public var draftTokens: Int

    public init(folder: URL, draftTokens: Int) {
        self.folder = folder
        self.draftTokens = draftTokens
    }
}

/// Which drafter `CleanupEngine.load` uses.
public enum DrafterChoice: Sendable {
    /// The drafter the manifest names, or none (what the app uses).
    /// `draftTokens` replaces the manifest's count.
    case fromManifest(draftTokens: Int? = nil)
    /// Another drafter folder (experiments; docs/models/speculative.md).
    case folder(Drafter)
    /// One token at a time with the model's usual class, ignoring the manifest.
    case off
}

/// How long loading took, step by step.
public struct LoadTimings: Sendable {
    public var verifySeconds: Double
    public var loadSeconds: Double
    public var warmupSeconds: Double
    public var totalSeconds: Double { verifySeconds + loadSeconds + warmupSeconds }
}

public enum CleanupEngineError: Error, LocalizedError {
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .notLoaded: "No cleanup model is loaded."
        }
    }
}

/// Loads a model folder and cleans transcripts with it. Keeps the model in
/// memory between calls; MLX's buffer cache is capped so it doesn't grow
/// past what one cleanup needs.
///
/// `load` awaits the model factory, and the actor takes other calls
/// meanwhile. `LoadSequence` makes the newest load or unload win: a load
/// that finds a newer one started drops what it loaded and throws
/// `CleanupBackendError.superseded`.
public actor CleanupEngine: CleanupBackend {
    /// MLX keeps freed buffers for reuse; this caps how much it keeps.
    public static let cacheLimitBytes = 256 << 20

    public nonisolated let prompt: CleanupPrompt
    public private(set) var manifest: ModelManifest?
    public private(set) var folder: URL?
    private var context: ModelContext?
    private var drafterModel: (any MTPDrafterModel)?
    /// The loaded drafter, or nil when the model decodes one token at a time.
    public private(set) var drafter: Drafter?
    /// Generation stops at these: the eos IDs from config.json and
    /// generation_config.json, the tokenizer's eos, and the chat template's
    /// end-of-turn token. Same rule as the Python CLI (generation.py).
    public private(set) var stopTokens: Set<Int> = []
    private var sequence = LoadSequence()

    /// End-of-turn tokens (Qwen, Gemma 4, older Gemma) and Qwen's
    /// <|endoftext|>, which config.json only lists under text_config. Same
    /// list as the Python CLI (generation.py).
    static let endOfTurnTokens = ["<|im_end|>", "<turn|>", "<end_of_turn>", "<|endoftext|>"]

    public init(prompt: CleanupPrompt) {
        self.prompt = prompt
        Memory.cacheLimit = Self.cacheLimitBytes
    }

    public var isLoaded: Bool { context != nil }

    /// Loads `folder`. Reads the manifest first and refuses the folder if it's
    /// missing, has an unknown schema, or was trained on another prompt
    /// version; with `verify`, also checks every file's checksum (the
    /// drafter's too). When the manifest names a drafter, loads it as well, and
    /// cleanups use speculative decoding. Then runs a one-token warm-up so the
    /// first cleanup doesn't pay for Metal setup.
    @discardableResult
    public func load(folder: URL, expectedID: String? = nil, verify: Bool = true,
                     drafter: DrafterChoice = .fromManifest()) async throws -> LoadTimings {
        try await load(folder: folder, expectedID: expectedID, verify: verify, drafter: drafter,
                       order: sequence.next).timings
    }

    public func load(folder: URL, expectedID: String?, verify: Bool, order: UInt64) async throws -> LoadedModel {
        let (id, timings) = try await load(folder: folder, expectedID: expectedID, verify: verify, order: order)
        return LoadedModel(id: id, seconds: timings.totalSeconds)
    }

    private func load(folder: URL, expectedID: String?, verify: Bool, drafter choice: DrafterChoice = .fromManifest(),
                      order: UInt64) async throws -> (id: String, timings: LoadTimings)
    {
        guard sequence.start(order) else { throw CleanupBackendError.superseded }
        dropModel()
        let clock = ContinuousClock()
        var manifest: ModelManifest!
        let verifyTime = try clock.measure {
            manifest = try ModelManifest.load(folder: folder, expectedID: expectedID)
            guard manifest.accepts(promptVersion: prompt.version) else {
                throw ModelFolderError.promptVersionMismatch(model: manifest.promptVersion ?? "", current: prompt.version)
            }
            if verify {
                try manifest.verify(folder: folder)
            }
        }
        let drafter: Drafter? = switch choice {
        case .off: nil
        case .folder(let drafter): drafter
        case .fromManifest(let count):
            manifest.drafter.flatMap { entry in
                manifest.drafterFolder(in: folder).map { Drafter(folder: $0, draftTokens: count ?? entry.draftTokens) }
            }
        }
        let start = clock.now
        // An unload or a newer load ran while the factory worked: the
        // weights were dropped inside `loadContext`, before it returned.
        guard let (context, drafterModel) = try await loadContext(folder: folder, drafter: drafter, order: order) else {
            throw CleanupBackendError.superseded
        }
        let loadTime = clock.now - start

        var stops = Self.configStopTokens(folder: folder)
        if let eos = context.tokenizer.eosTokenId {
            stops.insert(eos)
        }
        for token in Self.endOfTurnTokens {
            // Only tokens really in the vocabulary: an unknown one maps to <unk>.
            if let id = context.tokenizer.convertTokenToId(token), context.tokenizer.convertIdToToken(id) == token {
                stops.insert(id)
            }
        }
        self.context = context
        self.drafterModel = drafterModel
        self.drafter = drafter
        self.stopTokens = stops
        self.manifest = manifest
        self.folder = folder

        let warmup = try clock.measure {
            _ = try generate(messages: [ChatMessage(role: "user", content: "Hi")], maxTokens: 1)
        }
        return (manifest.id, LoadTimings(verifySeconds: verifyTime.seconds, loadSeconds: loadTime.seconds,
                                         warmupSeconds: warmup.seconds))
    }

    /// Runs the model factory, counted in `loadsInFlight`. Returns nil when
    /// a newer load or unload started meanwhile; the loaded weights are
    /// released before this returns, so an unload waiting for it knows the
    /// memory is free.
    private func loadContext(folder: URL, drafter: Drafter?, order: UInt64) async throws
        -> (ModelContext, (any MTPDrafterModel)?)?
    {
        loadsInFlight += 1
        defer {
            loadsInFlight -= 1
            if loadsInFlight == 0 {
                Memory.clearCache()
                let waiting = loadWaiters
                loadWaiters = []
                waiting.forEach { $0.resume() }
            }
        }
        return try await factoryLoad(folder: folder, drafter: drafter, order: order)
    }

    /// Kept apart from `loadContext` so a superseded context is released
    /// when this returns, before `loadContext` counts the load as done.
    private func factoryLoad(folder: URL, drafter: Drafter?, order: UInt64) async throws
        -> (ModelContext, (any MTPDrafterModel)?)?
    {
        guard let drafter else {
            let context = try await LLMModelFactory.shared.load(from: folder, using: LocalTokenizerLoader())
            return sequence.isCurrent(order) ? (context, nil) : nil
        }
        await Self.registerDrafters()
        let drafterModel = try await MTPDrafterModelFactory.shared.load(
            from: drafter.folder, using: LocalTokenizerLoader()).model
        // Gemma 4's assistant drafts only for MLXVLM's Gemma 4 class, which
        // also needs the vision tower's weights in the folder.
        let context = drafterModel is Gemma4AssistantDraftModel
            ? try await VLMModelFactory.shared.load(from: folder, using: LocalTokenizerLoader())
            : try await LLMModelFactory.shared.load(from: folder, using: LocalTokenizerLoader())
        return sequence.isCurrent(order) ? (context, drafterModel) : nil
    }

    private static func registerDrafters() async {
        await Gemma4AssistantRegistration.register()
        await Qwen35TextMTPRegistration.register()
    }

    /// Loads still running in the model factory. `unload` waits for them.
    public private(set) var loadsInFlight = 0
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []

    public func unload() async {
        await unload(order: sequence.next)
    }

    /// Drops the model. Returns only once no load is still reading weights,
    /// so the memory is free when the helper replies (training relies on
    /// this: shared/app-state.md "Starting training").
    public func unload(order: UInt64) async {
        // An older unload that arrives after a newer load does nothing.
        guard sequence.start(order) else { return }
        dropModel()
        while loadsInFlight > 0 {
            await withCheckedContinuation { loadWaiters.append($0) }
        }
    }

    private func dropModel() {
        context = nil
        drafterModel = nil
        drafter = nil
        manifest = nil
        folder = nil
        stopTokens = []
        Memory.clearCache()
    }

    /// Cleans one transcript with the shared prompt (the first
    /// `vocabulary_limit` terms). The caller parses the reply and runs the
    /// hard checks.
    public func clean(transcript: String, vocabulary: [String] = [],
                      deadline: ContinuousClock.Instant? = nil) throws -> GenerationResult {
        try generate(messages: prompt.messages(transcript: transcript, terms: prompt.usedTerms(vocabulary)),
                     deadline: deadline)
    }

    public func clean(transcript: String, vocabulary: [String], deadline: ContinuousClock.Instant) throws -> CleanResponse {
        let result = try clean(transcript: transcript, vocabulary: vocabulary, deadline: Optional(deadline))
        return CleanResponse(
            reply: result.timedOut ? nil : result.text, hitLimit: result.hitLimit, timedOut: result.timedOut,
            promptTokens: result.promptTokens.count, generatedTokens: result.tokens.count,
            promptSeconds: result.promptSeconds, generateSeconds: result.generateSeconds,
            error: result.timedOut ? "Cleanup passed its deadline." : nil)
    }

    /// Greedy decoding with the chat template and `chat_template_options`
    /// (speculative with a drafter: the model checks the drafted tokens and
    /// keeps the ones it would pick itself),
    /// stopping at an end-of-turn/eos token, `max_tokens`, or `deadline`
    /// (checked before the prompt and after every token; the prompt's own
    /// forward pass can't be interrupted).
    public func generate(messages: [ChatMessage], maxTokens: Int? = nil,
                         deadline: ContinuousClock.Instant? = nil) throws -> GenerationResult {
        guard let context else { throw CleanupEngineError.notLoaded }
        if let deadline, ContinuousClock.now >= deadline {
            return GenerationResult(promptTokens: [], tokens: [], text: "", stopToken: nil, timedOut: true,
                                    promptSeconds: 0, generateSeconds: 0)
        }
        let limit = maxTokens ?? prompt.generation.maxTokens
        let promptTokens = try context.tokenizer.applyChatTemplate(
            messages: messages.map { ["role": $0.role, "content": $0.content] },
            tools: nil,
            additionalContext: prompt.templateContext)

        var parameters = GenerateParameters(maxTokens: limit, temperature: 0)
        // Prompts up to 2048 tokens go through in one forward pass. Python
        // mlx-lm runs all but the last token first, then the last one; that
        // split was tried here and matched Python's tokens less often (75
        // vs 77 of 80 parity inputs), as MLX 0.32.2 (mlx-swift) and 0.32.4
        // (Python) already round differently.
        parameters.prefill = PrefillParameters(stepSize: 2048, chunking: .remainder)
        let clock = ContinuousClock()
        let start = clock.now
        let input = LMInput(tokens: MLXArray(promptTokens))
        var result: GenerationResult
        if let drafterModel, let drafter, drafter.draftTokens > 0 {
            var iterator = try MTPSpeculativeTokenIterator(
                input: input, mainModel: context.model, drafter: drafterModel, parameters: parameters,
                blockSize: drafter.draftTokens + 1)
            result = run(&iterator, deadline: deadline, clock: clock, start: start)
            result.draftedTokens = iterator.proposedCount
            result.acceptedTokens = iterator.acceptedCount
            result.draftingStopped = iterator.passthroughReason
        } else {
            var iterator = try TokenIterator(input: input, model: context.model, parameters: parameters)
            result = run(&iterator, deadline: deadline, clock: clock, start: start)
        }
        result.promptTokens = promptTokens
        result.text = context.tokenizer.decode(tokenIds: result.tokens, skipSpecialTokens: false)
        return result
    }

    /// The token loop for either iterator: stops at a stop token, the
    /// iterator's `max_tokens`, or `deadline`.
    private func run<Iterator: TokenIteratorProtocol>(
        _ iterator: inout Iterator, deadline: ContinuousClock.Instant?, clock: ContinuousClock,
        start: ContinuousClock.Instant
    ) -> GenerationResult {
        var tokens: [Int] = []
        var stopToken: Int?
        var timedOut = false
        while let token = iterator.next() {
            if stopTokens.contains(token) {
                stopToken = token
                break
            }
            tokens.append(token)
            if let deadline, clock.now >= deadline {
                timedOut = true
                break
            }
        }
        let total = clock.now - start
        return GenerationResult(
            promptTokens: [], tokens: tokens, text: "",
            stopToken: stopToken, timedOut: timedOut,
            promptSeconds: iterator.promptPrefillTime,
            generateSeconds: total.seconds - iterator.promptPrefillTime)
    }

    /// The eos IDs Python mlx-lm stops at: the top-level `eos_token_id` of
    /// config.json, replaced by generation_config.json's when that has one.
    /// mlx-swift-lm also reads `text_config.eos_token_id` (Qwen3.5's
    /// <|endoftext|>); mlx-lm doesn't, so neither do we, to give the same tokens.
    static func configStopTokens(folder: URL) -> Set<Int> {
        func eos(_ name: String) -> Set<Int>? {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let id = object["eos_token_id"] as? Int { return [id] }
            if let ids = object["eos_token_id"] as? [Int], !ids.isEmpty { return Set(ids) }
            return nil
        }
        return eos("generation_config.json") ?? eos("config.json") ?? []
    }

    /// Decodes token IDs, for showing where two runs differ.
    public func decode(_ tokens: [Int]) throws -> String {
        guard let context else { throw CleanupEngineError.notLoaded }
        return context.tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
    }
}

extension Duration {
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
