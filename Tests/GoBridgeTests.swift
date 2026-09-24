import XCTest

/// The C ABI as Swift sees it, against the real Go archive: an invalid or
/// absent profile, and every call on a handle that was never prepared, come
/// back as error messages. Nothing here prepares a real profile: that needs
/// root. The root-owned /etc/headwire must still exist, since the bridge
/// checks the directory before the file and otherwise reports it missing.
final class GoBridgeTests: XCTestCase {
    private let bridge = GoBridge()

    func testPreparingRejectsANameThatIsNotAProfile() {
        XCTAssertEqual(
            failure { _ = try bridge.prepare("../etc/shadow") },
            #"invalid configuration name "../etc/shadow""#)
    }

    func testPreparingReportsAMissingProfile() {
        XCTAssertEqual(
            failure { _ = try bridge.prepare("headwire-tests-absent") },
            "open /etc/headwire/headwire-tests-absent.conf: no such file or directory")
    }

    /// The handle is the process's one session, so every call on an unknown
    /// one is refused rather than acted on.
    func testCallsOnAnUnpreparedHandleAreRefused() {
        XCTAssertEqual(failure { _ = try bridge.status(99, field: "") }, "handle 99 is not running")
        // Start adopts the descriptor before it looks at the handle, so this
        // one is refused for the descriptor it was given.
        XCTAssertEqual(failure { try bridge.start(99, descriptor: -1) }, "bad file descriptor")
        bridge.stop(99)
        bridge.networkChanged(99, interface: "en0")
    }

    /// The message of the error the operation throws, failing when it returns.
    private func failure(
        _ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) -> String? {
        do {
            try operation()
        } catch {
            return error.localizedDescription
        }
        XCTFail("no error was thrown", file: file, line: line)
        return nil
    }
}
