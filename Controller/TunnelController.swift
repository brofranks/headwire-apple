import Foundation
@preconcurrency import NetworkExtension

/// What the controller needs of a NETunnelProviderManager, so tests can stand
/// in for NetworkExtension.
@MainActor
protocol TunnelManager: AnyObject {
    var providerBundleIdentifier: String? { get }
    func isSame(as other: TunnelManager) -> Bool
    /// The profile the provider loads, from its configuration.
    var name: String? { get }
    var status: NEVPNStatus { get }
    func removeFromPreferences() async throws
    func start() throws
    func stop()
    /// Waits for connected or disconnected. Start/stop can return while status
    /// still holds the old value for a moment. Observe before requesting the
    /// transition. The returned closure unsubscribes.
    func observeStatus(_ changed: @escaping () -> Void) -> () -> Void
    /// Why the provider stopped.
    func lastError() async -> String
}

/// Everything the apps can do to tunnels, free of terminal and UI code: the
/// macOS menu bar and command line and the iOS app all sit on it.
@MainActor
enum TunnelController {
    private static var operationInProgress = false
    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    @MainActor
    struct Profile {
        var name: String
        /// nil on macOS until `up` has registered the profile with
        /// NetworkExtension. A UI holds its profiles: NetworkExtension posts
        /// status changes only for managers that are still alive.
        var manager: TunnelManager?
        var status: NEVPNStatus? { manager?.status }
    }

    /// The installed profiles with the state of those already registered.
    /// A manager whose profile is gone is removed.
    static func profiles(installed: [String], managers: [TunnelManager]) async throws -> [Profile] {
        let managers = managers.filter(\.isOurs)
        for stale in managers where !installed.contains(stale.name ?? "") {
            try await stale.removeFromPreferences()
        }
        return installed.map { name in
            Profile(name: name, manager: managers.first { $0.name == name })
        }
    }

    static func up(_ manager: TunnelManager, managers: [TunnelManager]) async throws {
        try admit(manager)
        defer { operationInProgress = false }
        let ours = managers.filter(\.isOurs)
        // Deactivate before activating. Unlike a queued GUI selection, a
        // competing CLI request fails instead of replacing it.
        for peer in ours + [manager] {
            switch peer.status {
            case .connecting, .reasserting, .disconnecting:
                throw Failure(
                    errorDescription:
                        "\(peer.name ?? "Headwire"): a tunnel transition is already in progress")
            default: break
            }
        }
        for peer in ours where !peer.isSame(as: manager) && peer.status == .connected {
            try await TunnelTransition(peer, starting: false, timeout: 30).run()
        }
        // Starting a connected tunnel is a no-op that notifies no one, so
        // waiting for a status change would otherwise hang.
        guard manager.status != .connected else { return }
        do {
            try await TunnelTransition(manager, starting: true, timeout: 60).run()
        } catch is TunnelTransition.ConnectionFailed {
            throw Failure(
                errorDescription: "\(manager.name ?? "Headwire"): \(await manager.lastError())")
        }
    }

    static func down(managers: [TunnelManager]) async throws {
        for manager in managers where manager.isOurs {
            try await down(manager)
        }
    }

    static func down(_ manager: TunnelManager) async throws {
        try admit(manager)
        defer { operationInProgress = false }
        guard manager.status != .disconnected && manager.status != .invalid else { return }
        try await TunnelTransition(manager, starting: false, timeout: 30).run()
    }

    /// Saves manager as the Headwire profile name, which the provider reads
    /// from its configuration. configure adds what else the provider needs.
    static func register(
        _ manager: NETunnelProviderManager, name: String, configure: (NETunnelProviderProtocol) -> Void = { _ in }
    ) async throws {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Identifiers.providerExtension
        proto.serverAddress = name
        proto.providerConfiguration = ["name": name]
        configure(proto)
        manager.protocolConfiguration = proto
        manager.localizedDescription = name
        manager.isEnabled = true
        try await manager.saveToPreferences()
    }

    /// Claims the one transition slot. The caller releases it.
    private static func admit(_ manager: TunnelManager) throws {
        guard manager.isOurs else {
            throw Failure(errorDescription: "not a Headwire profile")
        }
        guard !operationInProgress else {
            throw Failure(errorDescription: "a Headwire tunnel transition is already in progress")
        }
        operationInProgress = true
    }

    /// One status field, `ip [-1|-4|-6]`, or `ping IP` from the running provider.
    static func status(_ manager: NETunnelProviderManager, field: String) async throws -> String {
        let request = try JSONEncoder().encode(ProviderRequest(statusField: field))
        let session = manager.connection as! NETunnelProviderSession
        return try status(from: try await reply { try session.sendProviderMessage(request, responseHandler: $0) })
    }

    /// The app's reading of a provider's answer.
    static func status(from data: Data?) throws -> String {
        let reply = try JSONDecoder().decode(ProviderReply.self, from: data ?? Data())
        guard reply.version == ProviderRequest.currentVersion, let status = reply.status else {
            throw Failure(errorDescription: reply.error ?? "unsupported reply")
        }
        return status
    }

    /// One provider reply with a deadline: NetworkExtension never calls the
    /// handler of a provider that is busy or gone. The first of reply and
    /// timeout wins, so a late reply is harmless.
    static func reply(timeout: TimeInterval = 5, to send: (@escaping @Sendable (Data?) -> Void) throws -> Void)
        async throws -> Data?
    {
        let pending = PendingReply()
        return try await withCheckedThrowingContinuation { continuation in
            pending.continuation = continuation
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                pending.finish(.failure(Diagnostics.timedOut))
            }
            do {
                try send { data in Task { @MainActor in pending.finish(.success(data)) } }
            } catch {
                pending.finish(.failure(error))
            }
        }
    }
}

extension TunnelManager {
    var isOurs: Bool { providerBundleIdentifier == Identifiers.providerExtension }
}

@MainActor
private final class PendingReply {
    var continuation: CheckedContinuation<Data?, Error>?

    func finish(_ result: Result<Data?, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

extension NETunnelProviderManager: TunnelManager {
    var providerBundleIdentifier: String? {
        (protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
    }

    func isSame(as other: TunnelManager) -> Bool {
        guard let other = other as? NETunnelProviderManager else { return false }
        return self == other
    }

    var name: String? {
        (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["name"] as? String
    }

    var status: NEVPNStatus { connection.status }

    func start() throws { try connection.startVPNTunnel() }

    func stop() { connection.stopVPNTunnel() }

    func observeStatus(_ changed: @escaping () -> Void) -> () -> Void {
        // The observer was installed on the main actor and the hop below runs
        // the callback there again, and nothing else touches it.
        nonisolated(unsafe) let changed = changed
        let token = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection, queue: nil
        ) { _ in
            // OperationQueue.main can block a CLI using dispatchMain() inside
            // notification delivery. Hop asynchronously to the main actor.
            Task { @MainActor in changed() }
        }
        return { NotificationCenter.default.removeObserver(token) }
    }

    /// NetworkExtension keeps the error the provider reported, which is the
    /// only way a root system extension's own failure reaches the app: its
    /// IPC is gone and it shares no app group container.
    func lastError() async -> String {
        let error: Error? = await withCheckedContinuation { continuation in
            connection.fetchLastDisconnectError { continuation.resume(returning: $0) }
        }
        return error?.localizedDescription
            ?? "did not connect, see: log show --last 1m --predicate 'subsystem == \"\(Identifiers.product)\"'"
    }
}
