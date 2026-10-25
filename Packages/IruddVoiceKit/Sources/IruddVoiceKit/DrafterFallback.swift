import Foundation

/// Speculative decoding only makes cleanup faster; it must never make it
/// fail. CleanupEngine runs the drafter path through these: when it throws,
/// the plain path runs instead, and the reason is reported (helper status,
/// clean replies, the app's events log).
public enum DrafterFallback {
    /// The drafter path's value, or the plain path's value and why the
    /// drafter path failed. A `CancellationError` isn't a drafter problem
    /// and is rethrown; so is an error from the plain path. Runs on the
    /// caller's actor, so the closures may use its state.
    public static func run<T>(isolation: isolated (any Actor)? = #isolation,
                              _ drafted: () async throws -> T,
                              otherwise plain: () async throws -> T) async throws -> (value: T, problem: String?) {
        do {
            return (try await drafted(), nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (try await plain(), reason(error))
        }
    }

    /// The same for synchronous work (starting the token iterator).
    public static func run<T>(_ drafted: () throws -> T,
                              otherwise plain: () throws -> T) throws -> (value: T, problem: String?) {
        do {
            return (try drafted(), nil)
        } catch {
            return (try plain(), reason(error))
        }
    }

    static func reason(_ error: any Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return text.isEmpty ? String(describing: type(of: error)) : text
    }
}
