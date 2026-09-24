import Foundation
import NetworkExtension

/// The JSON the bridge's prepare function returns (internal/apple.Settings in
/// headwire).
struct BridgeSettings: Codable, Equatable {
    struct Prefix: Codable, Equatable {
        var address: String
        var mask: String?
        var bits: Int
    }

    var mtu: Int
    var ipv4Addresses: [Prefix]?
    var ipv4Routes: [Prefix]?
    var ipv6Addresses: [Prefix]?
    var ipv6Routes: [Prefix]?
    var dnsServers: [String]?
    var dnsSearch: [String]?

    /// A default route arrives as `0.0.0.0` mask `0.0.0.0` or `::/0` and is
    /// installed as a route only: no `includeAllNetworks`,
    /// `excludeLocalNetworks` or `excludedRoutes`. DNS servers resolve every
    /// domain.
    func networkSettings() -> NEPacketTunnelNetworkSettings {
        // The tunnel has many remotes, but NetworkExtension wants one
        // placeholder.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: mtu)
        if let addresses = ipv4Addresses {
            let v4 = NEIPv4Settings(addresses: addresses.map(\.address), subnetMasks: addresses.map { $0.mask ?? "" })
            v4.includedRoutes = (ipv4Routes ?? []).map {
                NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.mask ?? "")
            }
            settings.ipv4Settings = v4
        }
        if let addresses = ipv6Addresses {
            // Cap interface prefixes at /120: Apple's stack can silently omit
            // the IPv6 default route with /128. This widens the OS subnet only.
            // Peer routes stay exact below.
            let v6 = NEIPv6Settings(
                addresses: addresses.map(\.address),
                networkPrefixLengths: addresses.map { NSNumber(value: min(120, $0.bits)) })
            v6.includedRoutes = (ipv6Routes ?? []).map {
                NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.bits))
            }
            settings.ipv6Settings = v6
        }
        let servers = dnsServers ?? []
        let search = dnsSearch ?? []
        if !servers.isEmpty || !search.isEmpty {
            let dns = NEDNSSettings(servers: servers)
            dns.searchDomains = search
            if !servers.isEmpty {
                dns.matchDomains = [""]
            }
            settings.dnsSettings = dns
        }
        return settings
    }
}
