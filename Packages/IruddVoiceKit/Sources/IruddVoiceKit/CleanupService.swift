import Foundation

/// The XPC service name of the cleanup helper embedded in the app
/// (Contents/XPCServices/IruddVoiceCleanup.xpc).
public let cleanupServiceName = "io.github.alundgren.irudd-voice.cleanup"

/// What the cleanup helper (IruddVoiceCleanup.xpc) answers to. Requests and
/// replies are JSON-encoded Codable values (`CleanupStatus`, `LoadRequest`, …),
/// so the interface stays four plain methods.
@objc public protocol CleanupServiceProtocol {
    func status(reply: @escaping @Sendable (Data) -> Void)
    func load(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    func clean(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
    func unload(reply: @escaping @Sendable (Data) -> Void)
}

public enum CleanupInterface {
    public static func make() -> NSXPCInterface {
        NSXPCInterface(with: CleanupServiceProtocol.self)
    }
}

/// The helper's state.
public struct CleanupStatus: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case empty, loading, ready, failed
    }

    public var state: State
    public var modelID: String?
    public var modelFolder: String?
    public var promptVersion: String?
    public var error: String?
    /// The helper process's resident memory, in bytes.
    public var residentBytes: UInt64?
    /// Ready with a drafter: cleanups use speculative decoding.
    public var drafting: Bool?
    /// Why the model's drafter isn't in use (it didn't load); the model
    /// then runs one token at a time.
    public var drafterProblem: String?

    public init(state: State, modelID: String? = nil, modelFolder: String? = nil, promptVersion: String? = nil,
                error: String? = nil, residentBytes: UInt64? = nil, drafting: Bool? = nil,
                drafterProblem: String? = nil) {
        self.state = state
        self.modelID = modelID
        self.modelFolder = modelFolder
        self.promptVersion = promptVersion
        self.error = error
        self.residentBytes = residentBytes
        self.drafting = drafting
        self.drafterProblem = drafterProblem
    }
}

/// Load a model by id (from the models folder) or by folder path.
public struct LoadRequest: Codable, Equatable, Sendable {
    public var modelID: String?
    public var folder: String?
    /// Check every file's checksum against the manifest first (default true).
    public var verify: Bool?

    public init(modelID: String? = nil, folder: String? = nil, verify: Bool? = nil) {
        self.modelID = modelID
        self.folder = folder
        self.verify = verify
    }
}

public struct LoadResponse: Codable, Equatable, Sendable {
    /// The helper's state after this request.
    public var status: CleanupStatus
    public var loadSeconds: Double?
    /// Why this load didn't happen, including "a newer load or unload replaced it".
    public var error: String?

    public init(status: CleanupStatus, loadSeconds: Double? = nil, error: String? = nil) {
        self.status = status
        self.loadSeconds = loadSeconds
        self.error = error
    }
}

public struct CleanRequest: Codable, Equatable, Sendable {
    public var transcript: String
    /// Vocabulary terms in file order; the helper uses the first `vocabulary_limit`.
    public var vocabulary: [String]
    /// How long the helper may spend, counted from when it receives the
    /// request (waiting for an earlier cleanup counts). Default: the prompt's
    /// `generation.timeout_seconds`.
    public var deadlineSeconds: Double?

    public init(transcript: String, vocabulary: [String] = [], deadlineSeconds: Double? = nil) {
        self.transcript = transcript
        self.vocabulary = vocabulary
        self.deadlineSeconds = deadlineSeconds
    }
}

/// The model's raw reply and how generation went. The caller parses it with
/// `CleanupReply.parse(_:hitLimit:)` and runs the hard checks.
public struct CleanResponse: Codable, Equatable, Sendable {
    public var reply: String?
    /// Generation stopped at `max_tokens` rather than an end-of-turn token.
    public var hitLimit: Bool
    /// Generation stopped at the deadline; `reply` is unfinished. Paste raw.
    public var timedOut: Bool
    public var promptTokens: Int
    public var generatedTokens: Int
    public var promptSeconds: Double
    public var generateSeconds: Double
    public var error: String?
    /// With a drafter: tokens it proposed and how many the model kept.
    public var draftedTokens: Int?
    public var acceptedTokens: Int?
    /// Why this cleanup didn't draft though the model has a drafter (it
    /// couldn't start, or stopped part-way). The reply is still the model's.
    public var drafterProblem: String?

    public init(reply: String?, hitLimit: Bool = false, timedOut: Bool = false, promptTokens: Int = 0,
                generatedTokens: Int = 0, promptSeconds: Double = 0, generateSeconds: Double = 0, error: String? = nil,
                draftedTokens: Int? = nil, acceptedTokens: Int? = nil, drafterProblem: String? = nil) {
        self.reply = reply
        self.hitLimit = hitLimit
        self.timedOut = timedOut
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.promptSeconds = promptSeconds
        self.generateSeconds = generateSeconds
        self.error = error
        self.draftedTokens = draftedTokens
        self.acceptedTokens = acceptedTokens
        self.drafterProblem = drafterProblem
    }
}

public enum CleanupClientError: Error, Equatable, LocalizedError {
    case timedOut
    /// The helper process stopped (crashed or was killed) during the call.
    /// It starts again, empty, on the next call: load the model again.
    case interrupted
    case connection(String)
    case badReply

    public var errorDescription: String? {
        switch self {
        case .timedOut: "The cleanup helper didn't answer in time."
        case .interrupted: "The cleanup helper stopped; it needs the model loaded again."
        case .connection(let message): "Lost the cleanup helper: \(message)"
        case .badReply: "The cleanup helper sent a reply that couldn't be read."
        }
    }
}

/// What the app needs from the cleanup helper. `CleanupClient` talks to the
/// real one over XPC; tests use a stand-in.
public protocol CleanupHelper: AnyObject, Sendable {
    func status(timeout: Duration) async throws -> CleanupStatus
    func load(_ request: LoadRequest, timeout: Duration) async throws -> LoadResponse
    /// `timeout` nil: the request's deadline plus `CleanupClient.cleanTimeoutMargin`.
    func clean(_ request: CleanRequest, timeout: Duration?) async throws -> CleanResponse
    func unload(timeout: Duration) async throws -> CleanupStatus
}

/// Talks to the cleanup helper. Every call has a timeout; a crashed or
/// interrupted helper is an error, never a hang.
///
/// - Interrupted (the helper process died): the call fails with
///   `.interrupted`, `onInterruption` runs, and the next call starts the
///   helper again, empty, so the app loads the model again.
/// - Invalidated (the connection can't be used any more): the next call
///   opens a new connection.
public final class CleanupClient: CleanupHelper, @unchecked Sendable {
    /// How much longer than the helper's deadline `clean` waits for an answer.
    public static let cleanTimeoutMargin: Duration = .seconds(1)
    /// The deadline `clean` assumes when the request has none
    /// (shared/cleanup-prompt.json `generation.timeout_seconds`).
    public static let defaultCleanDeadlineSeconds = 5.0

    private let makeConnection: @Sendable () -> NSXPCConnection
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var interruptionHandler: (@Sendable () -> Void)?
    private var interruptionCount = 0

    /// The helper embedded in the app.
    public convenience init() {
        self.init { NSXPCConnection(serviceName: cleanupServiceName) }
    }

    /// A helper behind a listener endpoint (tests use an anonymous listener).
    public convenience init(endpoint: NSXPCListenerEndpoint) {
        self.init { NSXPCConnection(listenerEndpoint: endpoint) }
    }

    init(makeConnection: @escaping @Sendable () -> NSXPCConnection) {
        self.makeConnection = makeConnection
    }

    deinit {
        connection?.invalidate()
    }

    /// Runs when the helper process stops during a session.
    public var onInterruption: (@Sendable () -> Void)? {
        get { lock.withLock { interruptionHandler } }
        set { lock.withLock { interruptionHandler = newValue } }
    }

    /// How many times the helper process stopped during a session.
    public var interruptions: Int { lock.withLock { interruptionCount } }

    public func status(timeout: Duration = .seconds(2)) async throws -> CleanupStatus {
        try await call(timeout: timeout) { service, reply in service.status(reply: reply) }
    }

    public func load(_ request: LoadRequest, timeout: Duration = .seconds(120)) async throws -> LoadResponse {
        let data = try JSONEncoder().encode(request)
        return try await call(timeout: timeout) { service, reply in service.load(data, reply: reply) }
    }

    /// Cleans one transcript. Waits `cleanTimeoutMargin` past the request's
    /// deadline unless `timeout` says otherwise; the helper itself stops at
    /// the deadline, so a late cleanup doesn't hold up the next one.
    public func clean(_ request: CleanRequest, timeout: Duration? = nil) async throws -> CleanResponse {
        let data = try JSONEncoder().encode(request)
        let wait = timeout ?? .seconds(request.deadlineSeconds ?? Self.defaultCleanDeadlineSeconds) + Self.cleanTimeoutMargin
        return try await call(timeout: wait) { service, reply in service.clean(data, reply: reply) }
    }

    public func unload(timeout: Duration = .seconds(5)) async throws -> CleanupStatus {
        try await call(timeout: timeout) { service, reply in service.unload(reply: reply) }
    }

    /// The open connection, or a new one after the last was invalidated.
    private func activeConnection() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let connection = makeConnection()
            connection.remoteObjectInterface = CleanupInterface.make()
            connection.interruptionHandler = { [weak self] in self?.interrupted() }
            connection.invalidationHandler = { [weak self, weak connection] in self?.invalidated(connection) }
            connection.resume()
            self.connection = connection
            return connection
        }
    }

    private func interrupted() {
        let handler = lock.withLock {
            interruptionCount += 1
            return interruptionHandler
        }
        handler?()
    }

    private func invalidated(_ old: NSXPCConnection?) {
        lock.withLock {
            if connection == nil || connection === old { connection = nil }
        }
    }

    private func call<Reply: Decodable & Sendable>(
        timeout: Duration,
        _ send: (CleanupServiceProtocol, @escaping @Sendable (Data) -> Void) -> Void
    ) async throws -> Reply {
        let once = Once<Reply>()
        return try await withCheckedThrowingContinuation { continuation in
            once.set(continuation)
            let proxy = activeConnection().remoteObjectProxyWithErrorHandler { error in
                let code = (error as NSError).code
                once.finish(.failure(code == NSXPCConnectionInterrupted
                    ? CleanupClientError.interrupted
                    : CleanupClientError.connection(error.localizedDescription)))
            }
            guard let service = proxy as? CleanupServiceProtocol else {
                once.finish(.failure(CleanupClientError.badReply))
                return
            }
            once.setTimer(Task {
                try? await Task.sleep(for: timeout)
                once.finish(.failure(CleanupClientError.timedOut))
            })
            send(service) { data in
                if let value = try? JSONDecoder().decode(Reply.self, from: data) {
                    once.finish(.success(value))
                } else {
                    once.finish(.failure(CleanupClientError.badReply))
                }
            }
        }
    }
}

/// Resumes a continuation exactly once, whichever of reply, error or
/// timeout comes first, and stops the timeout's task when the reply wins.
private final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
    private var timer: Task<Void, Never>?
    private var done = false

    func set(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setTimer(_ task: Task<Void, Never>) {
        lock.lock()
        if done {
            lock.unlock()
            task.cancel()
            return
        }
        timer = task
        lock.unlock()
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let timer = self.timer
        self.timer = nil
        guard let continuation else {
            pending = result
            lock.unlock()
            timer?.cancel()
            return
        }
        self.continuation = nil
        lock.unlock()
        timer?.cancel()
        continuation.resume(with: result)
    }
}
