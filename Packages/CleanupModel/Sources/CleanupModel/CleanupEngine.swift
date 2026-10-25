import Foundation
import IruddVoiceKit
import MLX
import MLXLLM
import MLXLMCommon

/// One greedy generation: the token IDs and how it went.
public struct GenerationResult: Sendable {
    /// The prompt after the chat template, as token IDs.
    public var promptTokens: [Int]
    /// The generated token IDs, without the end-of-turn token.
    public var tokens: [Int]
    /// The generated text (special tokens kept, so thinking tags show up).
    public var text: String
    /// The token that ended generation, or nil when it stopped at the limit.
    public var stopToken: Int?
    /// Stopped at `max_tokens` rather than an end-of-turn token.
    public var hitLimit: Bool { stopToken == nil }
    public var promptSeconds: Double
    public var generateSeconds: Double
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
public actor CleanupEngine {
    /// MLX keeps freed buffers for reuse; this caps how much it keeps.
    public static let cacheLimitBytes = 256 << 20

    public nonisolated let prompt: CleanupPrompt
    public private(set) var manifest: ModelManifest?
    public private(set) var folder: URL?
    private var context: ModelContext?
    /// Generation stops at these: the eos IDs from config.json and
    /// generation_config.json, the tokenizer's eos, and the chat template's
    /// end-of-turn token. Same rule as the Python CLI (generation.py).
    public private(set) var stopTokens: Set<Int> = []

    /// Chat-template end-of-turn tokens (Qwen, Gemma 4, older Gemma).
    static let endOfTurnTokens = ["<|im_end|>", "<turn|>", "<end_of_turn>"]

    public init(prompt: CleanupPrompt) {
        self.prompt = prompt
        Memory.cacheLimit = Self.cacheLimitBytes
    }

    public var isLoaded: Bool { context != nil }

    /// Loads `folder`. Reads the manifest first and refuses the folder if it's
    /// missing, has an unknown schema, or was trained on another prompt
    /// version; with `verify`, also checks every file's checksum. Then runs a
    /// one-token warm-up so the first cleanup doesn't pay for Metal setup.
    @discardableResult
    public func load(folder: URL, verify: Bool = true) async throws -> LoadTimings {
        unload()
        let clock = ContinuousClock()
        var manifest: ModelManifest!
        let verifyTime = try clock.measure {
            manifest = try ModelManifest.load(folder: folder)
            guard manifest.accepts(promptVersion: prompt.version) else {
                throw ModelFolderError.promptVersionMismatch(model: manifest.promptVersion ?? "", current: prompt.version)
            }
            if verify {
                try manifest.verify(folder: folder)
            }
        }
        let start = clock.now
        let context = try await LLMModelFactory.shared.load(from: folder, using: LocalTokenizerLoader())
        let loadTime = clock.now - start

        var stops = context.configuration.eosTokenIds
        if let eos = context.tokenizer.eosTokenId {
            stops.insert(eos)
        }
        for token in context.configuration.extraEOSTokens.union(Self.endOfTurnTokens) {
            // Only tokens really in the vocabulary: an unknown one maps to <unk>.
            if let id = context.tokenizer.convertTokenToId(token), context.tokenizer.convertIdToToken(id) == token {
                stops.insert(id)
            }
        }
        self.context = context
        self.stopTokens = stops
        self.manifest = manifest
        self.folder = folder

        let warmup = try clock.measure {
            _ = try generate(messages: [ChatMessage(role: "user", content: "Hi")], maxTokens: 1)
        }
        return LoadTimings(verifySeconds: verifyTime.seconds, loadSeconds: loadTime.seconds, warmupSeconds: warmup.seconds)
    }

    public func unload() {
        context = nil
        manifest = nil
        folder = nil
        stopTokens = []
        Memory.clearCache()
    }

    /// Cleans one transcript with the shared prompt. The caller parses the
    /// reply and runs the hard checks.
    public func clean(transcript: String, vocabulary: [String] = []) throws -> GenerationResult {
        try generate(messages: prompt.messages(transcript: transcript, terms: vocabulary))
    }

    /// Greedy decoding with the chat template and `chat_template_options`,
    /// stopping at an end-of-turn/eos token or `max_tokens`. Matches Python
    /// mlx-lm's `generate_step`: the prompt minus its last token is prefilled
    /// in steps of 2048, then decoding starts from the last token.
    public func generate(messages: [ChatMessage], maxTokens: Int? = nil) throws -> GenerationResult {
        guard let context else { throw CleanupEngineError.notLoaded }
        let limit = maxTokens ?? prompt.generation.maxTokens
        let promptTokens = try context.tokenizer.applyChatTemplate(
            messages: messages.map { ["role": $0.role, "content": $0.content] },
            tools: nil,
            additionalContext: prompt.templateContext)

        var parameters = GenerateParameters(maxTokens: limit, temperature: 0)
        parameters.prefill = PrefillParameters(stepSize: 2048, chunking: .remainder)
        let clock = ContinuousClock()
        let start = clock.now
        var iterator = try TokenIterator(
            input: LMInput(tokens: MLXArray(promptTokens)), model: context.model, parameters: parameters)
        var tokens: [Int] = []
        var stopToken: Int?
        while let token = iterator.next() {
            if stopTokens.contains(token) {
                stopToken = token
                break
            }
            tokens.append(token)
        }
        let total = clock.now - start
        let text = context.tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
        return GenerationResult(
            promptTokens: promptTokens, tokens: tokens, text: text,
            stopToken: stopToken,
            promptSeconds: iterator.promptPrefillTime,
            generateSeconds: total.seconds - iterator.promptPrefillTime)
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
