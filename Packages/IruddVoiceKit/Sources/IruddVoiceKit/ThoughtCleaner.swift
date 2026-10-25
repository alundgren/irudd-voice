import Foundation

/// The model the app uses when `active_model` is empty, and the fallback
/// when the active model can't be loaded. Picked in docs/models/baseline.md.
public enum CleanupDefaults {
    public static let modelID = "gemma-4-e2b-base-q4"
    /// The `irudd-voice models prepare` candidate that makes `modelID`.
    public static let prepareCandidate = "gemma-4-e2b"
}

/// What happened to a thought's cleanup, stored in `chunks.cleanup_status`.
/// Anything but `cleaned` means the raw text was pasted.
public enum CleanupOutcome: String, Sendable, Equatable, CaseIterable {
    case cleaned
    /// The training lease (`cleanup.unload_until`) is on.
    case unloadedForTraining = "unloaded_for_training"
    /// No model was loaded: still loading, failed to load, or none prepared.
    case noModel = "no_model"
    /// The helper couldn't be reached.
    case noHelper = "no_helper"
    /// The helper process stopped during the cleanup.
    case crash
    /// No answer within the deadline (`generation.timeout_seconds`).
    case timeout
    case cutOff = "cut_off"
    case thinkTags = "think_tags"
    case malformed
    /// The cleaned text failed a hard check (shared/README.md).
    case hardCheck = "hard_check"
    /// The model returned no text for a thought that had some.
    case empty
    /// The helper answered with an error.
    case helperError = "helper_error"
}

/// One thought's cleanup: what to paste and what to record.
public struct ThoughtCleanup: Sendable, Equatable {
    public var raw: String
    /// The cleaned text when `outcome` is `cleaned`, otherwise `raw`.
    public var pasteText: String
    public var outcome: CleanupOutcome
    public var modelID: String?
    public var promptVersion: String?
    public var milliseconds: Int64
    public var pieces: Int
    /// For the events log: what failed, and on which piece.
    public var detail: String

    public var record: CleanupRecord {
        CleanupRecord(status: outcome.rawValue, cleanedText: outcome == .cleaned ? pasteText : nil,
                      modelID: modelID, milliseconds: milliseconds, promptVersion: promptVersion)
    }

    /// Raw text without asking the model.
    public static func raw(_ text: String, _ outcome: CleanupOutcome, detail: String) -> ThoughtCleanup {
        ThoughtCleanup(raw: text, pasteText: text, outcome: outcome, modelID: nil, promptVersion: nil,
                       milliseconds: 0, pieces: 0, detail: detail)
    }
}

/// Cleans one thought with the loaded model: splits it (`ThoughtPieces`),
/// cleans each piece in order with the shared prompt's deadline, reads each
/// reply and runs the hard checks. Any failure on any piece means the whole
/// thought's raw text is pasted; the model's text is never pasted then.
public struct ThoughtCleaner: Sendable {
    public let helper: any CleanupHelper
    public let prompt: CleanupPrompt
    /// The vocabulary terms the prompt and the hard checks use.
    public let terms: [String]
    public let modelID: String
    public var maxWords = ThoughtPieces.maxWords

    public init(helper: any CleanupHelper, prompt: CleanupPrompt, terms: [String], modelID: String) {
        self.helper = helper
        self.prompt = prompt
        self.terms = prompt.usedTerms(terms)
        self.modelID = modelID
    }

    public func clean(_ transcript: String) async -> ThoughtCleanup {
        let clock = ContinuousClock()
        let start = clock.now
        let pieces = ThoughtPieces.split(transcript, maxWords: maxWords)
        func finish(_ outcome: CleanupOutcome, _ text: String, _ detail: String) -> ThoughtCleanup {
            let ms = Int64(((clock.now - start).inSeconds * 1000).rounded())
            return ThoughtCleanup(raw: transcript, pasteText: text, outcome: outcome, modelID: modelID,
                                  promptVersion: prompt.version, milliseconds: ms, pieces: pieces.count,
                                  detail: detail)
        }
        var cleaned: [String] = []
        for (index, piece) in pieces.enumerated() {
            switch await clean(piece: piece) {
            case .success(let text):
                cleaned.append(text)
            case .failure(let failure):
                let place = pieces.count > 1 ? " (piece \(index + 1) of \(pieces.count))" : ""
                return finish(failure.outcome, transcript, failure.detail + place)
            }
        }
        let joined = cleaned.filter { !$0.isEmpty }.joined(separator: " ")
        if joined.isEmpty {
            return finish(.empty, transcript, "The model returned no text.")
        }
        return finish(.cleaned, joined, pieces.count > 1 ? "Cleaned in \(pieces.count) pieces." : "Cleaned.")
    }

    struct Failure: Error {
        var outcome: CleanupOutcome
        var detail: String
    }

    func clean(piece: String) async -> Result<String, Failure> {
        let request = CleanRequest(transcript: piece, vocabulary: terms,
                                   deadlineSeconds: prompt.generation.timeoutSeconds)
        let response: CleanResponse
        do {
            response = try await helper.clean(request, timeout: nil)
        } catch CleanupClientError.timedOut {
            return .failure(Failure(outcome: .timeout, detail: "The helper didn't answer in time."))
        } catch CleanupClientError.interrupted {
            return .failure(Failure(outcome: .crash, detail: "The helper stopped during the cleanup."))
        } catch CleanupClientError.connection(let message) {
            return .failure(Failure(outcome: .noHelper, detail: "Couldn't reach the helper: \(message)"))
        } catch {
            return .failure(Failure(outcome: .helperError, detail: "The helper failed: \(error.localizedDescription)"))
        }
        if response.timedOut {
            return .failure(Failure(outcome: .timeout, detail: String(
                format: "Cleanup passed its %.0f s deadline.", prompt.generation.timeoutSeconds)))
        }
        guard let reply = response.reply, response.error == nil else {
            return .failure(Failure(outcome: .helperError, detail: response.error ?? "The helper sent no reply."))
        }
        let parsed = CleanupReply.parse(reply, hitLimit: response.hitLimit, key: prompt.outputKey)
        if let failure = parsed.failure {
            let outcome: CleanupOutcome = switch failure {
            case .thinkTags: .thinkTags
            case .cutOff: .cutOff
            case .malformed: .malformed
            }
            return .failure(Failure(outcome: outcome, detail: "Unusable reply (\(failure.rawValue)): \(Self.excerpt(reply))"))
        }
        let text = parsed.cleaned ?? ""
        let failed = HardChecks.check(
            transcript: piece, cleaned: text, vocabulary: terms,
            maxWordsRatio: prompt.checks.maxOutputWordsRatio, maxWordsSlack: prompt.checks.maxOutputWordsSlack)
        if !failed.isEmpty {
            return .failure(Failure(outcome: .hardCheck, detail:
                "Failed \(failed.joined(separator: ", ")); the model said: \(Self.excerpt(text))"))
        }
        return .success(text)
    }

    /// The start of a reply, for the log.
    static func excerpt(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
    }
}
