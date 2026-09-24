/// Called only on the provider's lifecycle queue. Admission belongs to Go,
/// and this state keeps it held until asynchronous settings work has finished.
final class ProviderSession {
    private enum State {
        case idle
        case starting(Int32, (Error?) -> Void, [() -> Void])
        case running(Int32)
    }
    private var state = State.idle
    private let release: (Int32) -> Void

    init(release: @escaping (Int32) -> Void) {
        self.release = release
    }

    var handle: Int32? {
        switch state {
        case .idle: return nil
        case .starting(let h, _, _), .running(let h): return h
        }
    }

    func begin(_ handle: Int32, completion: @escaping (Error?) -> Void) {
        precondition(self.handle == nil)
        state = .starting(handle, completion, [])
    }

    /// Also used for errors before settings are applied. The caller delivers
    /// exactly one completion for the pending application of network settings.
    func settingsApplied(_ error: Error?, startEngine: (Int32) throws -> Void) {
        guard case .starting(let handle, let started, let stopped) = state else { return }
        do {
            if !stopped.isEmpty { throw CancellationError() }
            if let error { throw error }
            try startEngine(handle)
            state = .running(handle)
            started(nil)
        } catch {
            teardown(handle, completions: [{ started(error) }] + stopped)
        }
    }

    /// Releases whatever this provider holds, in any state.
    func stop(completion: @escaping () -> Void) {
        switch state {
        case .idle: completion()
        case .starting(let h, let started, let stopped):
            // stopTunnel may have run while the settings were applied.
            // Keep admission until that callback and its cleanup finish.
            state = .starting(h, started, stopped + [completion])
        case .running(let h):
            teardown(h, completions: [completion])
        }
    }

    private func teardown(_ handle: Int32, completions: [() -> Void]) {
        // NetworkExtension removes routes/settings when the provider completes
        // stop (or reports a failed start).
        release(handle)
        state = .idle
        for completion in completions { completion() }
    }
}
