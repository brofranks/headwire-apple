import ServiceManagement
import XCTest

@MainActor
final class TunnelListTests: XCTestCase {
    private var loads = 0
    private var available: [String] = ["home"]
    private var loadFailure: Error?

    private lazy var list = TunnelList(
        load: { [unowned self] in
            self.loads += 1
            if let loadFailure = self.loadFailure { throw loadFailure }
            return self.available.map { TunnelController.Profile(name: $0, manager: nil) }
        },
        changed: {})

    func testReloadPublishesTheProfiles() async throws {
        XCTAssertEqual(list.profiles.map(\.name), [])
        try await list.reload()
        XCTAssertEqual(list.profiles.map(\.name), ["home"])
        XCTAssertEqual(loads, 1)
    }

    /// An unreadable configuration directory must not look like an empty one:
    /// the menu keeps what it had and the caller reports the failure.
    func testAFailedReloadKeepsTheProfilesAlreadyHeld() async throws {
        try await list.reload()
        loadFailure = failure("permission denied")
        let error = await thrown { try await self.list.reload() }
        XCTAssertEqual(error?.localizedDescription, "permission denied")
        XCTAssertEqual(list.profiles.map(\.name), ["home"])
    }

    func testWorkIsFollowedByAReload() async throws {
        try await list.attempt { self.available = ["home", "work"] }
        XCTAssertEqual(list.profiles.map(\.name), ["home", "work"])
    }

    /// `up` can register a profile and then fail to connect. The list must
    /// still pick the new profile up, and the failure still reach the caller.
    func testAFailedOperationStillReloads() async {
        let error = await thrown {
            try await self.list.attempt {
                self.available = ["home", "work"]
                throw failure("did not connect")
            }
        }
        XCTAssertEqual(error?.localizedDescription, "did not connect")
        XCTAssertEqual(list.profiles.map(\.name), ["home", "work"])
    }

    func testLoginItemStateDescribesWhatTheUserCanDo() {
        XCTAssertEqual(LoginItemState(.enabled), LoginItemState(title: "Launch at Login", on: true, actionable: true))
        XCTAssertEqual(LoginItemState(.notRegistered), LoginItemState())
        XCTAssertEqual(LoginItemState(.notFound), LoginItemState())
        XCTAssertEqual(
            LoginItemState(.requiresApproval),
            LoginItemState(title: "Launch at Login: Approval Required…", on: false, actionable: true))
    }
}
