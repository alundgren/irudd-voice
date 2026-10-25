import Foundation
import IruddVoiceKit

/// The cleanup helper's side of `CleanupServiceProtocol`, over a
/// `CleanupEngine`. The XPC service (App/IruddVoiceCleanup) exports one of
/// these; voice-model-tool's `xpc-check` runs it over an in-process listener.
public final class CleanupServiceHandler: NSObject, CleanupServiceProtocol, @unchecked Sendable {
    private let engine: CleanupEngine
    private let modelsFolder: URL
    private let lock = NSLock()
    private var current = CleanupStatus(state: .empty)

    public init(prompt: CleanupPrompt, modelsFolder: URL = ModelPaths.modelsFolder) {
        engine = CleanupEngine(prompt: prompt)
        self.modelsFolder = modelsFolder
    }

    private var state: CleanupStatus {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    private func snapshot() -> CleanupStatus {
        var status = state
        status.residentBytes = processFootprint().current
        return status
    }

    public func status(reply: @escaping @Sendable (Data) -> Void) {
        reply(encode(snapshot()))
    }

    public func load(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let request = try? JSONDecoder().decode(LoadRequest.self, from: request) else {
            reply(encode(LoadResponse(status: CleanupStatus(state: .failed, error: "Couldn't read the load request."))))
            return
        }
        let folder: URL
        if let path = request.folder {
            folder = URL(fileURLWithPath: path)
        } else if let id = request.modelID, ModelPaths.isValidID(id) {
            folder = modelsFolder.appendingPathComponent(id)
        } else {
            reply(encode(LoadResponse(status: CleanupStatus(state: .failed, error: "No valid model id or folder."))))
            return
        }
        state = CleanupStatus(state: .loading, modelFolder: folder.path)
        Task {
            do {
                let timings = try await engine.load(folder: folder, verify: request.verify ?? true)
                let manifest = await engine.manifest
                state = CleanupStatus(state: .ready, modelID: manifest?.id, modelFolder: folder.path,
                                      promptVersion: engine.prompt.version)
                reply(encode(LoadResponse(status: snapshot(), loadSeconds: timings.totalSeconds)))
            } catch {
                state = CleanupStatus(state: .failed, modelFolder: folder.path, error: error.localizedDescription)
                reply(encode(LoadResponse(status: snapshot())))
            }
        }
    }

    public func clean(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let request = try? JSONDecoder().decode(CleanRequest.self, from: request) else {
            reply(encode(CleanResponse(reply: nil, error: "Couldn't read the clean request.")))
            return
        }
        Task {
            do {
                let terms = engine.prompt.usedTerms(request.vocabulary)
                let result = try await engine.clean(transcript: request.transcript, vocabulary: terms)
                reply(encode(CleanResponse(
                    reply: result.text, hitLimit: result.hitLimit,
                    promptTokens: result.promptTokens.count, generatedTokens: result.tokens.count,
                    promptSeconds: result.promptSeconds, generateSeconds: result.generateSeconds)))
            } catch {
                reply(encode(CleanResponse(reply: nil, error: error.localizedDescription)))
            }
        }
    }

    public func unload(reply: @escaping @Sendable (Data) -> Void) {
        Task {
            await engine.unload()
            state = CleanupStatus(state: .empty)
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
