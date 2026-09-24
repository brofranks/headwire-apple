import NetworkExtension
import XCTest

/// Stands in for NetworkExtension: status changes on start and stop unless
/// `automatic` is off, in which case the test drives them with `update`.
@MainActor
final class FakeManager: TunnelManager {
    var providerBundleIdentifier: String? = Identifiers.providerExtension
    var name: String?
    var status: NEVPNStatus
    var outcome = NEVPNStatus.connected
    var startFailure: Error?
    var removalError: Error?
    var started = 0, stopped = 0, removed = 0
    var changed: (() -> Void)?
    var removedObservers = 0
    var automatic = true
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    init(_ name: String, _ status: NEVPNStatus = .disconnected) {
        self.name = name
        self.status = status
    }

    func isSame(as other: TunnelManager) -> Bool { self === other }
    func removeFromPreferences() async throws {
        if let removalError { throw removalError }
        removed += 1
    }
    func start() throws {
        started += 1
        onStart?()
        if let startFailure { throw startFailure }
        if automatic { update(outcome) }
    }
    func stop() {
        stopped += 1
        onStop?()
        if automatic { update(.disconnected) }
    }
    func update(_ next: NEVPNStatus) {
        status = next
        changed?()
    }
    func observeStatus(_ callback: @escaping () -> Void) -> () -> Void {
        XCTAssertNil(changed)
        changed = callback
        return {
            self.changed = nil
            self.removedObservers += 1
        }
    }
    func lastError() async -> String { "provider said no" }
}

/// Counts calls from a callback the system would deliver on its own queue.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func increment() {
        lock.withLock { calls += 1 }
    }
    var count: Int { lock.withLock { calls } }
}

func failure(_ message: String) -> Error {
    TunnelController.Failure(errorDescription: message)
}

/// The error the operation throws, failing the test when it returns.
/// Main-actor, like the tests and the controllers they drive, so the operation
/// never crosses an isolation boundary.
@MainActor
func thrown(
    _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
) async -> Error? {
    do {
        try await operation()
    } catch {
        return error
    }
    XCTFail("no error was thrown", file: file, line: line)
    return nil
}
