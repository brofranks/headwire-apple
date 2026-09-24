import XCTest

final class ProviderSessionTests: XCTestCase {
    func testStopDuringSettingsHoldsAdmissionAndNeverStartsEngine() {
        var events: [String] = []
        let session = ProviderSession { events.append("release \($0)") }
        session.begin(1) { error in
            XCTAssertTrue(error is CancellationError)
            events.append("start canceled")
        }
        session.stop { events.append("stop") }
        session.stop { events.append("second stop") }
        XCTAssertEqual(session.handle, 1)
        XCTAssertTrue(events.isEmpty)
        session.settingsApplied(nil) { _ in XCTFail("started after stop") }
        XCTAssertNil(session.handle)
        XCTAssertEqual(events, ["release 1", "start canceled", "stop", "second stop"])
        session.begin(2) { XCTAssertNil($0) }
        session.settingsApplied(nil) { XCTAssertEqual($0, 2) }
        XCTAssertEqual(session.handle, 2)
        session.stop {}
        XCTAssertEqual(events.last, "release 2")
    }

    func testSettingsAndEngineFailuresReleaseBeforeCompletingAndPermitRetry() {
        struct Failure: Error {}
        for settingsFail in [false, true] {
            var events: [String] = []
            let session = ProviderSession { events.append("release \($0)") }
            session.begin(1) {
                XCTAssertNotNil($0)
                events.append("failed")
            }
            XCTAssertEqual(session.handle, 1)
            session.settingsApplied(settingsFail ? Failure() : nil) { _ in
                XCTAssertFalse(settingsFail)
                throw Failure()
            }
            XCTAssertNil(session.handle)
            XCTAssertEqual(events, ["release 1", "failed"])
            session.begin(2) { XCTAssertNil($0) }
            session.settingsApplied(nil) { _ in }
            session.stop {}
            XCTAssertEqual(events.last, "release 2")
        }
    }

    func testNormalStopReleasesExactlyOnceBeforeCompleting() {
        var events: [String] = []
        let session = ProviderSession { _ in events.append("release") }
        session.begin(1) { XCTAssertNil($0) }
        session.settingsApplied(nil) { _ in }
        session.stop { events.append("stop") }
        session.stop { events.append("already stopped") }
        XCTAssertEqual(events, ["release", "stop", "already stopped"])
        XCTAssertNil(session.handle)
    }
}
