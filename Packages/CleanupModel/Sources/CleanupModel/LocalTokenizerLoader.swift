import Foundation
import Hub
import IruddVoiceKit
import MLXLMCommon
import Tokenizers

/// Loads a model folder's tokenizer with swift-transformers, from local files
/// only. mlx-swift-lm 3.x leaves tokenizers to the app; this replaces the
/// MLXHuggingFace macros, which would need macro validation in Xcode.
public struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    /// Tokenizer classes swift-transformers 1.3.5 doesn't list, and the
    /// listed class that loads them the same way. Qwen3.5's tokenizer.json is
    /// a plain byte-level BPE, like Qwen2's; the parity check
    /// (tests/model-parity.sh) confirms identical prompt tokens. Renaming the
    /// class up front avoids swift-transformers' non-strict fallback, which
    /// prints a warning to stdout on every load.
    static let classAliases = ["Qwen3_5Tokenizer": "Qwen2Tokenizer"]

    public init() {}

    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let files = LanguageModelConfigurationFromHub(modelFolder: directory)
        guard var config = try await files.tokenizerConfig else {
            throw Tokenizers.TokenizerError.missingConfig
        }
        if let name = config.tokenizerClass?.string(), let alias = Self.classAliases[name] {
            var dictionary = config.dictionary(or: [:])
            dictionary["tokenizer_class"] = Config(alias)
            config = Config(dictionary)
        }
        return TokenizerAdapter(try AutoTokenizer.from(tokenizerConfig: config, tokenizerData: try await files.tokenizerData))
    }
}

/// swift-transformers' tokenizer behind mlx-swift-lm's `Tokenizer` protocol.
struct TokenizerAdapter: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Just a model folder's tokenizer, for showing token IDs as text.
public struct TokenText: Sendable {
    let tokenizer: any MLXLMCommon.Tokenizer

    public init(folder: URL) async throws {
        tokenizer = try await LocalTokenizerLoader().load(from: folder)
    }

    public func text(_ ids: [Int]) -> String {
        tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)
    }

    /// The prompt's token IDs, built the way `CleanupEngine` builds them.
    public func promptTokens(_ messages: [ChatMessage], prompt: CleanupPrompt) throws -> [Int] {
        try tokenizer.applyChatTemplate(
            messages: messages.map { ["role": $0.role, "content": $0.content] },
            tools: nil, additionalContext: prompt.templateContext)
    }
}
