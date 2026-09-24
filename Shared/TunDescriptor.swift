import Darwin
import Foundation

/// NetworkExtension creates the utun once the network settings are applied and
/// offers no API for its descriptor, so look for the open descriptor that is a
/// utun kernel-control socket. A system extension can also hold an unconfigured
/// socket for a rejected concurrent provider. Require the interface with our
/// applied addresses.
enum TunDescriptor {
    static func find(settings: BridgeSettings) -> Int32? {
        select(
            descriptors: utunDescriptors(), addresses: interfaceAddresses(),
            expected: Set((settings.ipv4Addresses ?? []).map(\.address) + (settings.ipv6Addresses ?? []).map(\.address))
        )
    }

    /// Every interface's numeric addresses, without zone identifiers.
    static func interfaceAddresses() -> [String: Set<String>] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [:] }
        defer { freeifaddrs(interfaces) }
        var addresses: [String: Set<String>] = [:]
        var current = interfaces
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr,
                addr.pointee.sa_family == AF_INET || addr.pointee.sa_family == AF_INET6
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                    nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            addresses[String(cString: entry.pointee.ifa_name), default: []].insert(
                string(host).components(separatedBy: "%")[0])
        }
        return addresses
    }

    /// The utun kernel-control sockets this process holds, by interface name.
    static func utunDescriptors() -> [String: Int32] {
        var descriptors: [String: Int32] = [:]
        for fd: Int32 in 0...1024 {
            // sockaddr_ctl and SYSPROTO_CONTROL are missing from the iOS SDK,
            // but only the family is needed, so any sockaddr large enough will
            // do.
            var addr = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let connected = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
            }
            guard connected == 0, addr.ss_family == AF_SYSTEM else { continue }
            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            var nameLen = socklen_t(name.count)
            guard getsockopt(fd, 2 /* SYSPROTO_CONTROL */, 2 /* UTUN_OPT_IFNAME */, &name, &nameLen) == 0,
                string(name).hasPrefix("utun")
            else { continue }
            // A duplicated descriptor still names the same interface.
            if descriptors[string(name)] == nil { descriptors[string(name)] = fd }
        }
        return descriptors
    }

    /// The C string in a fixed buffer.
    private static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    static func select(
        descriptors: [String: Int32], addresses: [String: Set<String>],
        expected: Set<String>
    ) -> Int32? {
        guard !expected.isEmpty else { return nil }
        let matches = descriptors.filter { expected.isSubset(of: addresses[$0.key] ?? []) }
        guard matches.count == 1 else { return nil }
        return matches.first!.value
    }
}
