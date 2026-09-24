import Foundation
@preconcurrency import NetworkExtension

/// One notification-driven transition. Register before invoking the operation:
/// even a synchronous status change must not be lost. All callbacks run on
/// main.
@MainActor
final class TunnelTransition {
    struct ConnectionFailed: Error {}
    private let manager: TunnelManager
    private let starting: Bool
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<Void, Error>?
    private var unobserve: (() -> Void)?
    private var deadline: DispatchWorkItem?

    init(_ manager: TunnelManager, starting: Bool, timeout: TimeInterval) {
        self.manager = manager
        self.starting = starting
        self.timeout = timeout
    }

    func run() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                unobserve = manager.observeStatus { self.check(notification: true) }
                let deadline = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.finish(
                            TunnelController.Failure(
                                errorDescription: "\(self.manager.name ?? "Headwire"): timed out waiting to "
                                    + (self.starting ? "connect" : "disconnect")
                            ))
                    }
                }
                self.deadline = deadline
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
                do {
                    if starting { try manager.start() } else { manager.stop() }
                    check(notification: false)
                } catch {
                    finish(error)
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(CancellationError()) }
        }
    }

    private func check(notification: Bool) {
        guard continuation != nil else { return }
        switch manager.status {
        case .connected where starting:
            finish(nil)
        case .disconnected, .invalid:
            if !starting {
                finish(nil)
            } else if notification {
                finish(ConnectionFailed())
            }
        default: break
        }
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        unobserve?()
        unobserve = nil
        deadline?.cancel()
        deadline = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
