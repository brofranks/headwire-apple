import Foundation
import Network
@preconcurrency import NetworkExtension

/// The packet tunnel on both platforms: NetworkExtension's side of TunnelStart,
/// which owns the engine behind the Go bridge. Every member belongs to the
/// lifecycle queue.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    /// Owns the handle. Every bridge call runs here.
    private let lifecycle = DispatchQueue(label: "dev.brof.headwire.lifecycle")
    /// The default interface of the last path, for the engine's socket binding.
    private var interface = ""
    private lazy var tunnel = TunnelStart(
        bridge: GoBridge(),
        host: TunnelHost(
            apply: { [unowned self] settings, applied in
                // The utun exists only once the settings are applied.
                self.setTunnelNetworkSettings(settings.networkSettings(), completionHandler: applied)
            },
            descriptor: TunDescriptor.find(settings:),
            monitor: { [unowned self] in self.monitorPaths() },
            lifecycle: { [unowned self] work in self.lifecycle.async(execute: work) }))

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // NetworkExtension's completion handlers predate Sendable. Each is
        // called once, on the lifecycle queue this hop moves to.
        nonisolated(unsafe) let completionHandler = completionHandler
        lifecycle.async {
            let proto = self.protocolConfiguration as? NETunnelProviderProtocol
            // macOS names a root-owned /etc/headwire/<name>.conf, which the
            // bridge validates and loads. iOS passes the keychain's text.
            #if os(macOS)
                self.tunnel.start(
                    proto?.providerConfiguration?["name"] as? String ?? "", completion: completionHandler)
            #else
                do {
                    let text = try ProfileStore.read(proto?.passwordReference) ?? ""
                    self.tunnel.start(text, completion: completionHandler)
                } catch {
                    completionHandler(error)
                }
            #endif
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        nonisolated(unsafe) let completionHandler = completionHandler
        lifecycle.async {
            self.tunnel.stop(completion: completionHandler)
        }
    }

    /// Keeps the engine's endpoints current: an address or route change inside
    /// the extension does not reach the engine's own link monitor. Under a full
    /// tunnel the utun is the OS default, so this feed is also what keeps the
    /// engine's sockets on the physical interface. The returned closure stops
    /// it. Cancelled monitors cannot restart, so each tunnel gets its own.
    private func monitorPaths() -> () -> Void {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // NetworkExtension names the delegate interface once, at tunnel
            // creation, so the engine is told where the default route went.
            self.interface = TunnelStart.underlay(path.availableInterfaces.map { ($0.name, $0.type) })
            self.tunnel.networkChanged(self.interface)
        }
        // pathUpdateHandler runs here, where the handle is owned.
        monitor.start(queue: lifecycle)
        return { monitor.cancel() }
    }

    override func wake() {
        lifecycle.async {
            self.tunnel.networkChanged(self.interface)
        }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        nonisolated(unsafe) let completionHandler = completionHandler
        lifecycle.async {
            completionHandler?(try? JSONEncoder().encode(self.tunnel.answer(messageData)))
        }
    }
}
