import NetworkExtension
import XCTest

@MainActor
final class TunnelControllerTests: XCTestCase {
    func testProfilesMatchManagersAndRemoveStaleOnes() async throws {
        let home = FakeManager("home", .connected)
        let gone = FakeManager("gone", .disconnected)
        let profiles = try await TunnelController.profiles(installed: ["home", "work"], managers: [gone, home])
        XCTAssertEqual(profiles.map(\.name), ["home", "work"])
        XCTAssertIdentical(profiles[0].manager, home)
        XCTAssertNil(profiles[1].manager)
        XCTAssertEqual([home.removed, gone.removed], [0, 1])
    }

    /// Starting a connected tunnel notifies no one, so waiting would hang.
    func testUpLeavesAConnectedTunnelAlone() async throws {
        let manager = FakeManager("home", .connected)
        try await TunnelController.up(manager, managers: [manager])
        XCTAssertEqual(manager.started, 0)
    }

    func testUpReportsTheProvidersError() async {
        let manager = FakeManager("home", .disconnected)
        manager.outcome = .disconnected
        let error = await thrown { try await TunnelController.up(manager, managers: [manager]) }
        XCTAssertEqual(manager.started, 1)
        XCTAssertEqual(error?.localizedDescription, "home: provider said no")
        XCTAssertNil(manager.changed)
    }

    func testStartFailureIsReportedAndReleasesObserver() async {
        let manager = FakeManager("home", .disconnected)
        manager.startFailure = failure("start refused")
        let error = await thrown { try await TunnelController.up(manager, managers: [manager]) }
        XCTAssertEqual(error?.localizedDescription, "start refused")
        XCTAssertEqual(manager.removedObservers, 1)
        XCTAssertNil(manager.changed)
    }

    func testOtherProvidersProfilesAreRefused() async {
        let manager = FakeManager("other VPN", .connected)
        manager.providerBundleIdentifier = "another.extension"
        let operations: [() async throws -> Void] = [
            { try await TunnelController.up(manager, managers: [manager]) },
            { try await TunnelController.down(manager) },
        ]
        for operation in operations {
            let error = await thrown(operation)
            XCTAssertEqual(error?.localizedDescription, "not a Headwire profile")
        }
        XCTAssertEqual([manager.started, manager.stopped], [0, 0])
        // Refusal did not leave the transition slot claimed.
        try? await TunnelController.down(FakeManager("home", .connected))
    }

    func testDown() async throws {
        let up = FakeManager("home", .connected)
        let idle = FakeManager("work", .disconnected)
        try await TunnelController.down(up)
        try await TunnelController.down(idle)
        XCTAssertEqual([up.stopped, idle.stopped], [1, 0])
        XCTAssertEqual(up.status, .disconnected)
    }

    /// The two idle statuses are down's own guard. One active status stands
    /// for the rest, which all take the same transition.
    func testDownAllStopsOnlyActiveHeadwireProfiles() async throws {
        let active = FakeManager("home", .connected)
        let idle = [NEVPNStatus.disconnected, .invalid].map { FakeManager("idle", $0) }
        let unrelated = FakeManager("other VPN", .connected)
        unrelated.providerBundleIdentifier = "another.extension"
        try await TunnelController.down(managers: [active] + idle + [unrelated])
        XCTAssertEqual([active.stopped, idle[0].stopped, idle[1].stopped, unrelated.stopped], [1, 0, 0, 0])
        try await TunnelController.down(managers: [])
    }

    func testDownAllWaitsForDisconnection() async throws {
        let manager = FakeManager("home", .connecting)
        manager.automatic = false
        let stopping = expectation(description: "stop requested")
        manager.onStop = { stopping.fulfill() }
        var completed = false
        let task = Task {
            try await TunnelController.down(managers: [manager])
            completed = true
        }
        await fulfillment(of: [stopping], timeout: 2)
        XCTAssertFalse(completed)
        manager.update(.disconnecting)
        XCTAssertFalse(completed)
        manager.update(.disconnected)
        try await task.value
        XCTAssertTrue(completed)
        XCTAssertNil(manager.changed)
    }

    func testSwitchStopsAllOthersBeforeStartingAndLeavesOtherProvidersAlone() async throws {
        let a = FakeManager("a", .connected)
        let b = FakeManager("b", .connected)
        let target = FakeManager("target", .disconnected)
        let unrelated = FakeManager("other VPN", .connecting)
        unrelated.providerBundleIdentifier = "another.extension"
        target.onStart = {
            XCTAssertEqual(a.status, .disconnected)
            XCTAssertEqual(b.status, .disconnected)
        }
        try await TunnelController.up(target, managers: [a, b, unrelated, target])
        XCTAssertEqual([a.stopped, b.stopped, unrelated.stopped, target.started], [1, 1, 0, 1])
        XCTAssertEqual([a.removedObservers, b.removedObservers, target.removedObservers], [1, 1, 1])
    }

    func testConnectedTargetStillStopsDuplicatesAndUsesIdentityNotName() async throws {
        let target = FakeManager("same", .connected)
        let duplicate = FakeManager("same", .connected)
        try await TunnelController.up(target, managers: [target, duplicate])
        XCTAssertEqual([target.stopped, target.started, duplicate.stopped], [0, 0, 1])
    }

    func testTransitioningProfileRejectsActivationWithoutStoppingAnything() async {
        for status in [NEVPNStatus.connecting, .reasserting, .disconnecting] {
            let old = FakeManager("old", status)
            let target = FakeManager("target", .disconnected)
            let error = await thrown { try await TunnelController.up(target, managers: [old, target]) }
            XCTAssertEqual(error?.localizedDescription, "old: a tunnel transition is already in progress")
            XCTAssertEqual([old.stopped, target.started], [0, 0])
        }
    }

    func testOverlappingOperationIsRejectedAndSwitchWaitsForDisconnection() async throws {
        let old = FakeManager("old", .connected)
        let target = FakeManager("target", .disconnected)
        old.automatic = false
        let stopping = expectation(description: "stop requested")
        old.onStop = { stopping.fulfill() }
        let first = Task { try await TunnelController.up(target, managers: [old, target]) }
        await fulfillment(of: [stopping], timeout: 2)
        XCTAssertEqual(target.started, 0)
        let error = await thrown { try await TunnelController.up(target, managers: [old, target]) }
        XCTAssertEqual(error?.localizedDescription, "a Headwire tunnel transition is already in progress")
        old.update(.disconnected)
        try await first.value
        XCTAssertEqual(target.started, 1)
    }

    func testProviderReplyTimesOutAndIgnoresLateOrRepeatedReplies() async throws {
        var handler: (@Sendable (Data?) -> Void)?
        let timeout = await thrown { _ = try await TunnelController.reply(timeout: 0.01) { handler = $0 } }
        XCTAssertEqual(timeout?.localizedDescription, "provider request timed out")
        handler?(Data())
        let refused = await thrown { _ = try await TunnelController.reply { _ in throw failure("busy") } }
        XCTAssertEqual(refused?.localizedDescription, "busy")
        let data = try await TunnelController.reply {
            $0(Data("ok".utf8))
            $0(nil)
        }
        XCTAssertEqual(data, Data("ok".utf8))
    }

    func testTransitionTimeoutAndCancellationRemoveObservers() async {
        for starting in [false, true] {
            let manager = FakeManager("stuck", starting ? .disconnected : .connected)
            manager.automatic = false
            let error = await thrown { try await TunnelTransition(manager, starting: starting, timeout: 0.01).run() }
            XCTAssertEqual(
                error?.localizedDescription, "stuck: timed out waiting to \(starting ? "connect" : "disconnect")")
            XCTAssertNil(manager.changed)
            XCTAssertEqual(manager.removedObservers, 1)
        }
        let manager = FakeManager("canceled", .connected)
        manager.automatic = false
        let stopping = expectation(description: "stop requested")
        manager.onStop = { stopping.fulfill() }
        let task = Task { try await TunnelTransition(manager, starting: false, timeout: 30).run() }
        await fulfillment(of: [stopping], timeout: 2)
        task.cancel()
        let error = await thrown { try await task.value }
        XCTAssertTrue(error is CancellationError)
        XCTAssertNil(manager.changed)
    }

    func testInitiallyInvalidStatusDoesNotFailBeforeStartNotification() async throws {
        let manager = FakeManager("new", .invalid)
        manager.automatic = false
        let started = expectation(description: "start requested")
        manager.onStart = { started.fulfill() }
        let task = Task { try await TunnelTransition(manager, starting: true, timeout: 60).run() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertNotNil(manager.changed)
        manager.update(.connected)
        try await task.value
    }

    func testFailedReplacementLeavesOldProfileDisconnected() async {
        let old = FakeManager("old", .connected)
        let target = FakeManager("target", .disconnected)
        target.outcome = .disconnected
        let error = await thrown { try await TunnelController.up(target, managers: [old, target]) }
        XCTAssertEqual(error?.localizedDescription, "target: provider said no")
        XCTAssertEqual(old.status, .disconnected)
        XCTAssertEqual(old.started, 0)
    }
}
