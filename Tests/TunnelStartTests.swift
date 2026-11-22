import Network
import XCTest

/// Stands in for the Go engine, recording the calls the provider makes.
private final class FakeBridge: Bridge {
    var settings = #"""
        {"mtu":1280,"ipv4Addresses":[{"address":"10.9.0.1","mask":"255.255.255.0","bits":24}]}
        """#
    var prepareFailure: Error?
    var startFailure: Error?
    var calls: [String] = []

    func prepare(_ source: String) throws -> (handle: Int32, settings: String) {
        calls.append("prepare \(source)")
        if let prepareFailure { throw prepareFailure }
        return (7, settings)
    }
    func start(_ handle: Int32, descriptor: Int32) throws {
        calls.append("start \(handle) fd \(descriptor)")
        if let startFailure { throw startFailure }
    }
    func stop(_ handle: Int32) { calls.append("stop \(handle)") }
    func status(_ handle: Int32, field: String) -> String { "status \(handle) \(field)" }
    func networkChanged(_ handle: Int32, interface: String) { calls.append("interface \(interface)") }
}

/// One tunnel with its fakes, driven synchronously: `apply` holds its
/// completion so a test decides when the utun exists.
private final class Fixture {
    let bridge = FakeBridge()
    var applied: ((Error?) -> Void)?
    var monitoring = 0
    var descriptor: Int32? = 4
    var completions: [Error?] = []
    lazy var tunnel = TunnelStart(
        bridge: bridge,
        host: TunnelHost(
            apply: { [unowned self] _, done in
                self.bridge.calls.append("apply")
                self.applied = done
            },
            descriptor: { [unowned self] _ in self.descriptor },
            monitor: { [unowned self] in
                self.monitoring += 1
                self.bridge.calls.append("monitor")
                return { self.monitoring -= 1 }
            },
            // The provider hops back to its lifecycle queue, and a test is on
            // it.
            lifecycle: { $0() }))

    func start(_ source: String = "main") {
        tunnel.start(source) { [unowned self] in self.completions.append($0) }
    }

    /// The single completion's message, or nil when the start succeeded.
    func message(file: StaticString = #filePath, line: UInt = #line) -> String? {
        XCTAssertEqual(completions.count, 1, "one completion", file: file, line: line)
        return completions.first??.localizedDescription
    }
}

final class TunnelStartTests: XCTestCase {
    func testStartAppliesSettingsThenStartsTheEngineOnTheUtun() {
        let it = Fixture()
        it.start()
        it.applied?(nil)
        XCTAssertNil(it.message())
        XCTAssertEqual(it.tunnel.handle, 7)
        // Monitoring feeds the engine its underlay before the routes go in.
        XCTAssertEqual(it.bridge.calls, ["prepare main", "monitor", "apply", "start 7 fd 4"])
        XCTAssertEqual(it.monitoring, 1)

        it.tunnel.networkChanged("en0")
        var stopped = 0
        it.tunnel.stop { stopped += 1 }
        XCTAssertEqual(it.bridge.calls.suffix(2), ["interface en0", "stop 7"])
        XCTAssertEqual(stopped, 1)
        XCTAssertNil(it.tunnel.handle)
        XCTAssertEqual(it.monitoring, 0)
    }

    func testPreparationFailureHoldsNothing() {
        let it = Fixture()
        it.bridge.prepareFailure = Diagnostics.failure("no such profile")
        it.start("gone")
        XCTAssertEqual(it.message(), "no such profile")
        XCTAssertNil(it.tunnel.handle)
        XCTAssertEqual(it.bridge.calls, ["prepare gone"])
        XCTAssertEqual(it.monitoring, 0)
    }

    func testRoutesRequireAnInterfaceAddressInTheirFamily() {
        let v4 = #""ipv4Addresses":[{"address":"100.64.0.1","mask":"255.255.255.255","bits":32}]"#
        let v6 = #""ipv6Addresses":[{"address":"fd42::1","bits":128}]"#
        for (family, addresses, routes) in [
            ("IPv4", v6, #""ipv4Addresses":[],"ipv4Routes":[{"address":"0.0.0.0","mask":"0.0.0.0","bits":0}]"#),
            ("IPv4", v6, #""ipv4Routes":[{"address":"192.0.2.0","mask":"255.255.255.0","bits":24}]"#),
            ("IPv6", v4, #""ipv6Addresses":[],"ipv6Routes":[{"address":"::","bits":0}]"#),
            ("IPv6", v4, #""ipv6Routes":[{"address":"2001:db8::","bits":64}]"#),
        ] {
            let it = Fixture()
            it.bridge.settings = #"{"mtu":1280,\#(addresses),\#(routes)}"#
            it.start()
            XCTAssertEqual(it.message(), "\(family) routes require an \(family) Address in [Interface]")
            XCTAssertEqual(it.bridge.calls, ["prepare main", "stop 7"])
            XCTAssertNil(it.tunnel.handle)
        }
        // Routes in a family with an address go on to be applied.
        let it = Fixture()
        it.bridge.settings =
            #"{"mtu":1280,\#(v4),\#(v6),"ipv4Routes":[{"address":"0.0.0.0","mask":"0.0.0.0","bits":0}],"#
            + #""ipv6Routes":[{"address":"::","bits":0}]}"#
        it.start()
        XCTAssertEqual(it.bridge.calls, ["prepare main", "monitor", "apply"])
    }

    /// Every failure after preparation must release the engine's handle, the
    /// process's one session, and report once.
    func testFailuresAfterPreparationReleaseTheHandle() {
        let cases: [(name: String, arrange: (Fixture) -> Void, applied: Error?)] = [
            ("settings", { $0.bridge.settings = "not json" }, nil),
            ("apply", { _ in }, Diagnostics.failure("settings were refused")),
            ("descriptor", { $0.descriptor = nil }, nil),
            ("engine", { $0.bridge.startFailure = Diagnostics.failure("engine refused") }, nil),
        ]
        for (name, arrange, failure) in cases {
            let it = Fixture()
            arrange(it)
            it.start()
            it.applied?(failure)
            XCTAssertNotNil(it.message(), name)
            XCTAssertNil(it.tunnel.handle, name)
            XCTAssertEqual(it.bridge.calls.last, "stop 7", name)
            XCTAssertEqual(it.monitoring, 0, name)
        }
    }

    /// stopTunnel can arrive while the settings are still being applied. The
    /// engine must not start, and both callers hear back exactly once.
    func testStopWhileApplyingSettingsCancelsTheStart() {
        let it = Fixture()
        it.start()
        var stopped = 0
        it.tunnel.stop { stopped += 1 }
        XCTAssertEqual(stopped, 0, "admission is held until the apply returns")

        it.applied?(nil)
        XCTAssertNotNil(it.message())
        XCTAssertEqual(stopped, 1)
        XCTAssertNil(it.tunnel.handle)
        XCTAssertFalse(it.bridge.calls.contains { $0.hasPrefix("start ") })
        XCTAssertEqual(it.bridge.calls.last, "stop 7")
        XCTAssertEqual(it.monitoring, 0)
    }

    func testStatusNeedsARunningEngine() {
        let it = Fixture()
        XCTAssertEqual(it.tunnel.answer(Self.request("")).error, "not running")
        it.start()
        it.applied?(nil)
        XCTAssertEqual(it.tunnel.answer(Self.request("listen-port")).status, "status 7 listen-port")
        XCTAssertEqual(it.tunnel.answer(Data("{}".utf8)).error, "unsupported request")
    }

    private static func request(_ field: String) -> Data {
        try! JSONEncoder().encode(ProviderRequest(statusField: field))
    }

    func testUnderlayIsThePhysicalInterfaceBehindTheTunnel() {
        XCTAssertEqual(TunnelStart.underlay([("utun4", .other), ("en0", .wifi)]), "en0")
        XCTAssertEqual(TunnelStart.underlay([("lo0", .loopback), ("utun4", .other)]), "")
        XCTAssertEqual(TunnelStart.underlay([]), "")
    }
}
