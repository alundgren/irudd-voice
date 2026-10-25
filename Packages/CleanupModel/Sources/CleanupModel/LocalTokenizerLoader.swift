import Foundation
import IruddVoiceKit
import MLXLMCommon
import Tokenizers

/// Loads a model folder's tokenizer with swift-transformers, from local files
/// only. mlx-swift-lm 3.x leaves tokenizers to the app; this replaces the
/// MLXHuggingFace macros, which would need macro validation in Xcode.
public struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    /// Tokenizer classes swift-transformers 1.3.5 doesn't list but loads
    /// correctly with its generic BPE tokenizer (what it uses for
    /// Qwen2Tokenizer): Qwen3.5's tokenizer.json is a plain byte-level BPE.
    /// The parity check (tests/model-parity.sh) confirms identical prompt tokens.
    static let plainBPEClasses: Set<String> = ["Qwen3_5Tokenizer"]

    public init() {}

    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        do {
            return TokenizerAdapter(try await AutoTokenizer.from(modelFolder: directory))
        } catch Tokenizers.TokenizerError.unsupportedTokenizer(let name) where Self.plainBPEClasses.contains(name) {
            return TokenizerAdapter(try await AutoTokenizer.from(modelFolder: directory, strict: false))
        }
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
