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

    public init(state: State, modelID: String? = nil, modelFolder: String? = nil, promptVersion: String? = nil,
                error: String? = nil, residentBytes: UInt64? = nil) {
        self.state = state
        self.modelID = modelID
        self.modelFolder = modelFolder
        self.promptVersion = promptVersion
        self.error = error
        self.residentBytes = residentBytes
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
    public var status: CleanupStatus
    public var loadSeconds: Double?

    public init(status: CleanupStatus, loadSeconds: Double? = nil) {
        self.status = status
        self.loadSeconds = loadSeconds
    }
}

public struct CleanRequest: Codable, Equatable, Sendable {
    public var transcript: String
    /// Vocabulary terms in file order; the helper uses the first `vocabulary_limit`.
    public var vocabulary: [String]

    public init(transcript: String, vocabulary: [String] = []) {
        self.transcript = transcript
        self.vocabulary = vocabulary
    }
}

/// The model's raw reply and how generation went. The caller parses it with
/// `CleanupReply.parse(_:hitLimit:)` and runs the hard checks.
public struct CleanResponse: Codable, Equatable, Sendable {
    public var reply: String?
    /// Generation stopped at `max_tokens` rather than an end-of-turn token.
    public var hitLimit: Bool
    public var promptTokens: Int
    public var generatedTokens: Int
    public var promptSeconds: Double
    public var generateSeconds: Double
    public var error: String?

    public init(reply: String?, hitLimit: Bool = false, promptTokens: Int = 0, generatedTokens: Int = 0,
                promptSeconds: Double = 0, generateSeconds: Double = 0, error: String? = nil) {
        self.reply = reply
        self.hitLimit = hitLimit
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.promptSeconds = promptSeconds
        self.generateSeconds = generateSeconds
        self.error = error
    }
}

public enum CleanupClientError: Error, Equatable, LocalizedError {
    case timedOut
    case connection(String)
    case badReply

    public var errorDescription: String? {
        switch self {
        case .timedOut: "The cleanup helper didn't answer in time."
        case .connection(let message): "Lost the cleanup helper: \(message)"
        case .badReply: "The cleanup helper sent a reply that couldn't be read."
        }
    }
}

/// Talks to the cleanup helper. Every call has a timeout; a crashed or
/// interrupted helper is an error, never a hang. After an interruption the
/// next call relaunches the helper, which starts empty, so callers check
/// `status()` and load again.
public final class CleanupClient: @unchecked Sendable {
    private let connection: NSXPCConnection

    /// The helper embedded in the app.
    public convenience init() {
        self.init(connection: NSXPCConnection(serviceName: cleanupServiceName))
    }

    /// A helper behind a listener endpoint (tests use an anonymous listener).
    public convenience init(endpoint: NSXPCListenerEndpoint) {
        self.init(connection: NSXPCConnection(listenerEndpoint: endpoint))
    }

    init(connection: NSXPCConnection) {
        self.connection = connection
        connection.remoteObjectInterface = CleanupInterface.make()
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    public func status(timeout: Duration = .seconds(2)) async throws -> CleanupStatus {
        try await call(timeout: timeout) { service, reply in service.status(reply: reply) }
    }

    public func load(_ request: LoadRequest, timeout: Duration = .seconds(120)) async throws -> LoadResponse {
        let data = try JSONEncoder().encode(request)
        return try await call(timeout: timeout) { service, reply in service.load(data, reply: reply) }
    }

    public func clean(_ request: CleanRequest, timeout: Duration = .seconds(5)) async throws -> CleanResponse {
        let data = try JSONEncoder().encode(request)
        return try await call(timeout: timeout) { service, reply in service.clean(data, reply: reply) }
    }

    public func unload(timeout: Duration = .seconds(5)) async throws -> CleanupStatus {
        try await call(timeout: timeout) { service, reply in service.unload(reply: reply) }
    }

    private func call<Reply: Decodable & Sendable>(
        timeout: Duration,
        _ send: (CleanupServiceProtocol, @escaping @Sendable (Data) -> Void) -> Void
    ) async throws -> Reply {
        let once = Once<Reply>()
        return try await withCheckedThrowingContinuation { continuation in
            once.set(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.finish(.failure(CleanupClientError.connection(error.localizedDescription)))
            }
            guard let service = proxy as? CleanupServiceProtocol else {
                once.finish(.failure(CleanupClientError.badReply))
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                once.finish(.failure(CleanupClientError.timedOut))
            }
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
/// timeout comes first.
private final class Once<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
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

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        guard let continuation else {
            pending = result
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
