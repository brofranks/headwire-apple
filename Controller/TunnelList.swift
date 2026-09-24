import Foundation
@preconcurrency import NetworkExtension

/// The profiles a user interface shows, and the rules both apps share for
/// keeping them current: the managers stay held (NetworkExtension posts status
/// changes only for live ones), a status change redraws without re-listing,
/// and anything that may add or remove a profile re-lists afterwards.
@MainActor
final class TunnelList {
    private let load: @MainActor () async throws -> [TunnelController.Profile]
    private(set) var profiles: [TunnelController.Profile] = []

    /// `changed` is called for every tunnel status change, which only redraws:
    /// listing managers posts the same notification, so re-listing here would
    /// never stop. The observation lasts as long as the list, which in both
    /// apps is the life of the process.
    init(
        load: @escaping @MainActor () async throws -> [TunnelController.Profile],
        changed: @escaping @MainActor () -> Void
    ) {
        self.load = load
        NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { _ in
            Task { @MainActor in changed() }
        }
    }

    /// Re-lists, keeping the profiles already held if listing fails: an
    /// unreadable configuration directory must not look like an empty one.
    func reload() async throws {
        profiles = try await load()
    }

    /// Runs work and re-lists whether or not it succeeded: starting a profile
    /// can register one the list did not hold yet, and the failure is the
    /// caller's to report.
    func attempt(_ work: @MainActor () async throws -> Void) async throws {
        do {
            try await work()
        } catch {
            try? await reload()
            throw error
        }
        try await reload()
    }
}
