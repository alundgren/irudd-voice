import Foundation

/// A model the backend loaded.
public struct LoadedModel: Equatable, Sendable {
    public var id: String
    public var seconds: Double

    public init(id: String, seconds: Double) {
        self.id = id
        self.seconds = seconds
    }
}

public enum CleanupBackendError: Error, Equatable, LocalizedError {
    case superseded

    public var errorDescription: String? {
        switch self {
        case .superseded: "A newer load or unload replaced this load."
        }
    }
}

/// What the cleanup helper runs models with: `CleanupEngine`
/// (Packages/CleanupModel) in the helper, a stand-in in tests.
///
/// Loads and unloads carry an `order` that grows with every one the helper
/// receives. The newest one wins: a load must give up (throw `.superseded`
/// and keep nothing loaded) once a newer load or unload has started, and an
/// older unload arriving late does nothing. `LoadSequence` keeps track.
public protocol CleanupBackend: Sendable {
    func load(folder: URL, expectedID: String?, verify: Bool, order: UInt64) async throws -> LoadedModel
    func unload(order: UInt64) async
    /// Generation must stop at `deadline` and report `timedOut`.
    func clean(transcript: String, vocabulary: [String], deadline: ContinuousClock.Instant) async throws -> CleanResponse
}

/// The newest load or unload a backend has started.
public struct LoadSequence: Sendable {
    public private(set) var latest: UInt64 = 0

    public init() {}

    /// Starts an operation. False when a newer one has already started; the
    /// operation must then not touch the loaded model.
    public mutating func start(_ order: UInt64) -> Bool {
        guard order > latest else { return false }
        latest = order
        return true
    }

    /// Whether `order` is still the newest operation (check after every await).
    public func isCurrent(_ order: UInt64) -> Bool {
        order == latest
    }

    /// An order for callers that don't number their own operations.
    public var next: UInt64 { latest + 1 }
}

/// The cleanup helper's side of `CleanupServiceProtocol`. The XPC service
/// (App/IruddVoiceCleanup) exports one over `CleanupEngine`;
/// voice-model-tool's `xpc-check` runs the same over an in-process listener.
///
/// Every load and unload gets an order number when it arrives, and only the
/// newest one may set the state, so an unload during a load ends with
/// nothing loaded and `.empty`, and two loads end with the second model.
public final class CleanupServiceHandler: NSObject, CleanupServiceProtocol, @unchecked Sendable {
    private let backend: any CleanupBackend
    private let prompt: CleanupPrompt
    private let modelsFolder: URL
    private let lock = NSLock()
    private var current = CleanupStatus(state: .empty)
    private var latestOrder: UInt64 = 0

    public init(prompt: CleanupPrompt, backend: any CleanupBackend, modelsFolder: URL = ModelPaths.modelsFolder) {
        self.prompt = prompt
        self.backend = backend
        self.modelsFolder = modelsFolder
    }

    private func nextOrder() -> UInt64 {
        lock.withLock {
            latestOrder += 1
            return latestOrder
        }
    }

    /// Sets the state only while `order` is the newest load or unload.
    @discardableResult
    private func setState(_ status: CleanupStatus, ifLatest order: UInt64) -> Bool {
        lock.withLock {
            guard order == latestOrder else { return false }
            current = status
            return true
        }
    }

    private func snapshot() -> CleanupStatus {
        var status = lock.withLock { current }
        status.residentBytes = processFootprint().current
        return status
    }

    public func status(reply: @escaping @Sendable (Data) -> Void) {
        reply(encode(snapshot()))
    }

    public func load(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let request = try? JSONDecoder().decode(LoadRequest.self, from: request) else {
            refuse("Couldn't read the load request.", reply)
            return
        }
        let folder: URL
        var expectedID: String?
        if let path = request.folder {
            folder = URL(fileURLWithPath: path)
        } else if let id = request.modelID, let idFolder = ModelPaths.folder(forModel: id, in: modelsFolder) {
            folder = idFolder
            expectedID = id
        } else {
            refuse("No valid model id or folder.", reply)
            return
        }
        let order = nextOrder()
        setState(CleanupStatus(state: .loading, modelFolder: folder.path), ifLatest: order)
        Task {
            do {
                let model = try await backend.load(
                    folder: folder, expectedID: expectedID, verify: request.verify ?? true, order: order)
                let ready = CleanupStatus(state: .ready, modelID: model.id, modelFolder: folder.path,
                                          promptVersion: prompt.version)
                if setState(ready, ifLatest: order) {
                    reply(encode(LoadResponse(status: snapshot(), loadSeconds: model.seconds)))
                } else {
                    reply(encode(LoadResponse(status: snapshot(), error: CleanupBackendError.superseded.localizedDescription)))
                }
            } catch {
                setState(CleanupStatus(state: .failed, modelFolder: folder.path, error: error.localizedDescription),
                         ifLatest: order)
                reply(encode(LoadResponse(status: snapshot(), error: error.localizedDescription)))
            }
        }
    }

    /// A request that can't be carried out changes nothing.
    private func refuse(_ message: String, _ reply: @escaping @Sendable (Data) -> Void) {
        reply(encode(LoadResponse(status: snapshot(), error: message)))
    }

    public func clean(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let request = try? JSONDecoder().decode(CleanRequest.self, from: request) else {
            reply(encode(CleanResponse(reply: nil, error: "Couldn't read the clean request.")))
            return
        }
        // Counted from arrival, so time spent waiting behind another cleanup counts.
        let deadline = ContinuousClock.now + .seconds(request.deadlineSeconds ?? prompt.generation.timeoutSeconds)
        let terms = prompt.usedTerms(request.vocabulary)
        Task {
            do {
                reply(encode(try await backend.clean(transcript: request.transcript, vocabulary: terms, deadline: deadline)))
            } catch {
                reply(encode(CleanResponse(reply: nil, error: error.localizedDescription)))
            }
        }
    }

    public func unload(reply: @escaping @Sendable (Data) -> Void) {
        let order = nextOrder()
        Task {
            await backend.unload(order: order)
            setState(CleanupStatus(state: .empty), ifLatest: order)
            reply(encode(snapshot()))
        }
    }

    private func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}

/// This process's memory footprint now and at its peak, in bytes (what
/// Activity Monitor shows as Memory; includes Metal buffers).
public func processFootprint() -> (current: UInt64, peak: UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }
    return (info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak)))
}
