import NetworkExtension
import XCTest

final class SharedTests: XCTestCase {
    func testProfileNames() {
        XCTAssertTrue(ProfileName.isValid("home-2_a"))
        for name in ["", "../etc/passwd", "a/b", "a.conf", "a b"] {
            XCTAssertFalse(ProfileName.isValid(name), name)
        }
        XCTAssertEqual(
            ProfileName.installed(["work.conf", "home.conf", "notes.txt", "a b.conf", ".conf", "conf"]),
            ["home", "work"])
    }

    /// The literal is the settings JSON the Go bridge emits.
    func testBridgeSettings() throws {
        let json = """
            {"mtu":1280,"ipv4Addresses":[{"address":"100.64.0.1","mask":"255.255.255.255","bits":32}],\
            "ipv4Routes":[{"address":"0.0.0.0","mask":"0.0.0.0","bits":0},{"address":"10.1.0.0","mask":"255.255.0.0","bits":16},\
            {"address":"100.64.0.2","mask":"255.255.255.255","bits":32}],\
            "ipv6Addresses":[{"address":"fd00::1","bits":128}],\
            "ipv6Routes":[{"address":"::","bits":0},{"address":"fd00::2","bits":128}],\
            "dnsServers":["100.64.0.53"],"dnsSearch":["corp.example"]}
            """
        let settings = try JSONDecoder().decode(BridgeSettings.self, from: Data(json.utf8)).networkSettings()
        XCTAssertEqual(settings.mtu, 1280)
        XCTAssertEqual(settings.ipv4Settings?.addresses, ["100.64.0.1"])
        XCTAssertEqual(
            settings.ipv4Settings?.includedRoutes?.map(\.destinationSubnetMask),
            ["0.0.0.0", "255.255.0.0", "255.255.255.255"])
        XCTAssertEqual(settings.ipv6Settings?.networkPrefixLengths, [120])
        XCTAssertEqual(settings.ipv6Settings?.includedRoutes?.map(\.destinationNetworkPrefixLength), [0, 128])
        XCTAssertEqual(settings.dnsSettings?.servers, ["100.64.0.53"])
        XCTAssertEqual(settings.dnsSettings?.searchDomains, ["corp.example"])
        XCTAssertEqual(settings.dnsSettings?.matchDomains, [""])
    }

    func testIPv6InterfacePrefixClampPreservesRoutes() {
        let prefixes = [64, 120, 127, 128].map {
            BridgeSettings.Prefix(address: "fd00::1", bits: $0)
        }
        let routes = [0, 64, 120, 127, 128].map {
            BridgeSettings.Prefix(address: "::", bits: $0)
        }
        let settings = BridgeSettings(mtu: 1280, ipv6Addresses: prefixes, ipv6Routes: routes).networkSettings()
        XCTAssertEqual(settings.ipv6Settings?.addresses, prefixes.map(\.address))
        XCTAssertEqual(settings.ipv6Settings?.networkPrefixLengths, [64, 120, 120, 120])
        XCTAssertEqual(
            settings.ipv6Settings?.includedRoutes?.map(\.destinationNetworkPrefixLength), [0, 64, 120, 127, 128])
    }

    func testBridgeSettingsWithoutDNS() throws {
        let json =
            #"{"mtu":1280,"ipv4Addresses":null,"ipv4Routes":null,"ipv6Addresses":null,"ipv6Routes":null,"dnsServers":null,"dnsSearch":null}"#
        let settings = try JSONDecoder().decode(BridgeSettings.self, from: Data(json.utf8)).networkSettings()
        XCTAssertNil(settings.dnsSettings)
        XCTAssertNil(settings.ipv4Settings)
        XCTAssertNil(settings.ipv6Settings)
    }

    /// Search domains alone do not claim every query.
    func testSearchDomainsWithoutServers() {
        let settings = BridgeSettings(mtu: 1280, dnsSearch: ["corp.example"]).networkSettings()
        XCTAssertEqual(settings.dnsSettings?.servers, [])
        XCTAssertEqual(settings.dnsSettings?.searchDomains, ["corp.example"])
        XCTAssertNil(settings.dnsSettings?.matchDomains)
    }

    func testProviderMessageRoundTrip() throws {
        for field in ["dump", "ip", "ip -1", "ip -4", "ip -6"] {
            let request = ProviderRequest(statusField: field)
            XCTAssertEqual(try JSONDecoder().decode(ProviderRequest.self, from: JSONEncoder().encode(request)), request)
        }
    }

    /// The app's request through the provider's answer and back.
    @MainActor
    func testProviderAnswers() throws {
        let request = try JSONEncoder().encode(ProviderRequest(statusField: "ip -4"))
        var asked: [(Int32, String)] = []
        let answered = ProviderReply.answer(request, handle: 7) {
            asked.append(($0, $1))
            return "100.64.0.1\n"
        }
        XCTAssertEqual(try TunnelController.status(from: try JSONEncoder().encode(answered)), "100.64.0.1\n")
        XCTAssertEqual(asked.map(\.0), [7])
        XCTAssertEqual(asked.map(\.1), ["ip -4"])

        let unasked: (Int32, String) -> String = { _, _ in
            XCTFail("a failed encode must not reach the provider")
            return ""
        }
        let failures = [
            (ProviderReply.answer(request, handle: nil, status: unasked), "not running"),
            (ProviderReply.answer(Data("junk".utf8), handle: 7, status: unasked), "unsupported request"),
            (
                ProviderReply.answer(try JSONEncoder().encode(ProviderReply(version: 2)), handle: 7, status: unasked),
                "unsupported request"
            ),
            (ProviderReply.answer(request, handle: 7) { _, _ in throw failure("unknown field") }, "unknown field"),
        ]
        for (reply, message) in failures {
            XCTAssertEqual(reply.error, message)
            XCTAssertNil(reply.status)
            XCTAssertThrowsError(try TunnelController.status(from: try JSONEncoder().encode(reply))) {
                XCTAssertEqual($0.localizedDescription, message)
            }
        }
        XCTAssertThrowsError(try TunnelController.status(from: nil))
        XCTAssertThrowsError(
            try TunnelController.status(from: try JSONEncoder().encode(ProviderReply(version: 2, status: "x")))
        ) {
            XCTAssertEqual($0.localizedDescription, "unsupported reply")
        }
    }
}
