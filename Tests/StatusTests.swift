import NetworkExtension
import XCTest

@MainActor
final class StatusTests: XCTestCase {
    func testListWording() {
        XCTAssertEqual(describe(nil), "unregistered")
        let named: [NEVPNStatus: String] = [
            .connected: "connected", .connecting: "connecting", .disconnecting: "disconnecting",
            .reasserting: "reasserting", .invalid: "invalid", .disconnected: "disconnected",
        ]
        for (status, name) in named {
            XCTAssertEqual(describe(status), name)
        }
    }

    func testMenuMarksAndSummary() {
        let profiles = [
            TunnelController.Profile(name: "a", manager: FakeManager("a", .connected)),
            TunnelController.Profile(name: "b", manager: FakeManager("b", .connecting)),
            TunnelController.Profile(name: "c", manager: nil),
            TunnelController.Profile(name: "d", manager: FakeManager("d", .disconnected)),
        ]
        var state = MenuState(profiles)
        XCTAssertEqual(state.entries.map(\.mark), [.on, .mixed, .off, .off])
        XCTAssertEqual(state.entries.map(\.title), ["a", "b", "c", "d"])
        XCTAssertEqual(state.summary, "Connected: a")
        XCTAssertTrue(state.connected)

        state = MenuState(Array(profiles.dropFirst()))
        XCTAssertEqual(state.summary, "Connection changing: b")
        XCTAssertFalse(state.connected)

        state = MenuState(Array(profiles.dropFirst(2)))
        XCTAssertEqual(state.summary, "Not connected")

        state = MenuState([])
        XCTAssertTrue(state.entries.isEmpty)
        XCTAssertEqual(state.summary, "Not connected")
    }
}
