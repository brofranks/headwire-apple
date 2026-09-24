import XCTest

final class TunDescriptorTests: XCTestCase {
    func testRejectsUnconfiguredSocketFromConcurrentProvider() {
        let selected = TunDescriptor.select(
            descriptors: ["utun7": 3, "utun4": 10],
            addresses: ["utun7": [], "utun4": ["10.77.0.1", "fd77::1", "fe80::1"]],
            expected: ["10.77.0.1", "fd77::1"])
        XCTAssertEqual(selected, 10)
    }

    func testRequiresAllConfiguredAddressesOnOneUniqueInterface() {
        let descriptors: [String: Int32] = ["utun4": 3, "utun7": 10]
        XCTAssertNil(
            TunDescriptor.select(
                descriptors: descriptors,
                addresses: ["utun4": ["10.77.0.1"], "utun7": ["fd77::1"]],
                expected: ["10.77.0.1", "fd77::1"]))
        XCTAssertNil(
            TunDescriptor.select(
                descriptors: descriptors,
                addresses: ["utun4": ["10.77.0.1"], "utun7": ["10.77.0.1"]], expected: ["10.77.0.1"]))
        XCTAssertNil(TunDescriptor.select(descriptors: descriptors, addresses: [:], expected: []))
        XCTAssertEqual(
            TunDescriptor.select(
                descriptors: descriptors,
                addresses: ["utun4": ["10.77.0.1"], "utun7": ["fd77::1"]], expected: ["fd77::1"]), 10)
    }

    /// The scans run against this process: loopback is always configured, and
    /// a test holds no utun.
    func testScansThisProcess() {
        let loopback = TunDescriptor.interfaceAddresses()["lo0"] ?? []
        XCTAssertTrue(loopback.isSuperset(of: ["127.0.0.1", "::1"]), "\(loopback)")
        XCTAssertTrue(loopback.allSatisfy { !$0.contains("%") })
        XCTAssertTrue(TunDescriptor.utunDescriptors().isEmpty)
        XCTAssertNil(
            TunDescriptor.find(
                settings: BridgeSettings(mtu: 1280, ipv4Addresses: [.init(address: "127.0.0.1", bits: 32)])))
    }
}
