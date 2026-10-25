import Foundation

/// A value in `chat_template_options`, passed to the model's chat template.
public enum TemplateOption: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    /// The plain value, for a chat template's extra context.
    public var value: any Sendable {
        switch self {
        case .bool(let value): value
        case .int(let value): value
        case .string(let value): value
        }
    }
}

/// One chat message for the model.
public struct ChatMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// The cleanup prompt from shared/cleanup-prompt.json. The Python CLI
/// (cli/src/irudd_voice/prompt.py) builds byte-identical messages from the
/// same file; shared/README.md "Building the prompt" has the rules.
public struct CleanupPrompt: Codable, Equatable, Sendable {
    public struct Generation: Codable, Equatable, Sendable {
        public var temperature: Double
        public var maxTokens: Int
        public var timeoutSeconds: Double

        enum CodingKeys: String, CodingKey {
            case temperature
            case maxTokens = "max_tokens"
            case timeoutSeconds = "timeout_seconds"
        }
    }

    public struct Checks: Codable, Equatable, Sendable {
        public var maxOutputWordsRatio: Double
        public var maxOutputWordsSlack: Int

        enum CodingKeys: String, CodingKey {
            case maxOutputWordsRatio = "max_output_words_ratio"
            case maxOutputWordsSlack = "max_output_words_slack"
        }
    }

    public var version: String
    public var system: String
    public var vocabularyTemplate: String
    public var userTemplate: String
    public var rule: String
    public var outputKey: String
    public var vocabularyLimit: Int
    public var generation: Generation
    public var checks: Checks
    public var chatTemplateOptions: [String: TemplateOption]

    enum CodingKeys: String, CodingKey {
        case version, system, rule, generation, checks
        case vocabularyTemplate = "vocabulary_template"
        case userTemplate = "user_template"
        case outputKey = "output_key"
        case vocabularyLimit = "vocabulary_limit"
        case chatTemplateOptions = "chat_template_options"
    }

    public static func load(from url: URL) throws -> CleanupPrompt {
        try JSONDecoder().decode(CleanupPrompt.self, from: Data(contentsOf: url))
    }

    /// The terms the prompt and the hard checks use: the first `vocabularyLimit`, in file order.
    public func usedTerms(_ terms: [String]) -> [String] {
        Array(terms.prefix(vocabularyLimit))
    }

    /// The `[system, user]` messages for one cleanup.
    public func messages(transcript: String, terms: [String] = []) -> [ChatMessage] {
        var systemText = system
        let used = usedTerms(terms)
        if !used.isEmpty {
            systemText += Self.fill(vocabularyTemplate, ["terms": used.joined(separator: ", ")])
        }
        let user = Self.fill(userTemplate, ["input_json": Self.inputJSON(transcript), "rule": rule])
        return [ChatMessage(role: "system", content: systemText), ChatMessage(role: "user", content: user)]
    }

    /// The chat template options as extra template context (`enable_thinking`: false).
    public var templateContext: [String: any Sendable] {
        chatTemplateOptions.mapValues { $0.value }
    }

    /// A JSON string literal with only the required escapes: quote, backslash
    /// and control characters. "/" and non-ASCII stay as they are.
    public static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20:
                out += "\\u00" + String(format: "%02x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    public static func inputJSON(_ transcript: String) -> String {
        "{\"transcript\": " + jsonString(transcript) + "}"
    }

    /// Replaces `{name}` placeholders in one pass, so text inside a value (a
    /// transcript saying "{rule}") is never expanded.
    public static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "}"), let value = values[String(after[..<close])] {
                out += value
                rest = after[after.index(after: close)...]
            } else {
                out += "{"
                rest = after
            }
        }
        return out + rest
    }
}
