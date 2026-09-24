import Foundation
import Network

/// What the start sequence needs of NetworkExtension, so that sequence itself
/// runs in a test. Every closure is called on the lifecycle queue except
/// `apply`'s completion, which is why `lifecycle` exists.
struct TunnelHost {
    /// Applies the tunnel's network settings. The utun exists once it returns.
    /// NetworkExtension calls back on a queue of its own choosing, hence
    /// `lifecycle` below.
    var apply: (BridgeSettings, @escaping @Sendable (Error?) -> Void) -> Void
    /// The engine's utun, among this process's descriptors.
    var descriptor: (BridgeSettings) -> Int32?
    /// Starts feeding the engine default-interface changes. The closure it
    /// returns stops that feed.
    var monitor: () -> () -> Void
    /// Runs work back on the lifecycle queue, where the handle is owned.
    var lifecycle: (@escaping @Sendable () -> Void) -> Void
}

/// The packet tunnel's own logic: prepare the configuration, apply the
/// settings it yields, find the utun and start the engine, holding admission
/// across every asynchronous step. Confined to the provider's lifecycle queue.
final class TunnelStart: @unchecked Sendable {
    private let bridge: Bridge
    private let host: TunnelHost
    private var stopMonitor: () -> Void = {}
    private lazy var session = ProviderSession { [unowned self] handle in
        self.stopMonitor()
        self.stopMonitor = {}
        self.bridge.stop(handle)
    }

    init(bridge: Bridge, host: TunnelHost) {
        self.bridge = bridge
        self.host = host
    }

    var handle: Int32? { session.handle }

    /// The physical interface a path runs over: `.other` is the utun itself.
    static func underlay(_ interfaces: [(name: String, type: NWInterface.InterfaceType)]) -> String {
        interfaces.first { $0.type != .other && $0.type != .loopback }?.name ?? ""
    }

    func start(_ source: String, completion: @escaping (Error?) -> Void) {
        let prepared: (handle: Int32, settings: String)
        do {
            prepared = try bridge.prepare(source)
        } catch {
            return completion(error)
        }
        session.begin(prepared.handle, completion: completion)
        let settings: BridgeSettings
        do {
            settings = try JSONDecoder().decode(BridgeSettings.self, from: Data(prepared.settings.utf8))
        } catch {
            return session.settingsApplied(Diagnostics.failure("settings: \(error)")) { _ in }
        }
        // Before the routes go in, so the engine knows the underlay when it
        // binds its first socket behind a default route.
        stopMonitor = host.monitor()
        host.apply(settings) { [self] failure in
            host.lifecycle {
                self.session.settingsApplied(failure) { handle in
                    guard let descriptor = self.host.descriptor(settings) else {
                        throw Diagnostics.failure("no unique utun descriptor matching the tunnel addresses")
                    }
                    try self.bridge.start(handle, descriptor: descriptor)
                }
            }
        }
    }

    func stop(completion: @escaping () -> Void) {
        session.stop(completion: completion)
    }

    /// A no-op before the engine runs: the bridge is told where the default
    /// route went, which only a started engine can act on.
    func networkChanged(_ interface: String) {
        guard let handle else { return }
        bridge.networkChanged(handle, interface: interface)
    }

    /// The app's status request, answered by the running engine.
    func answer(_ messageData: Data) -> ProviderReply {
        ProviderReply.answer(messageData, handle: handle) { try bridge.status($0, field: $1) }
    }
}
