import Foundation
@preconcurrency import NetworkExtension

#if os(macOS)

    /// macOS profiles are the configurations installed in /etc/headwire. The
    /// directory is listable, but the files are not readable.
    @MainActor
    enum InstalledProfiles {
        static func all() async throws -> [TunnelController.Profile] {
            // A missing directory is a first run with no profiles, not an
            // error. An unreadable one is: listing it as empty would drop every
            // registration.
            let installed = ProfileName.installed(
                FileManager.default.fileExists(atPath: ProfileName.configDirectory)
                    ? try FileManager.default.contentsOfDirectory(atPath: ProfileName.configDirectory) : [])
            return try await TunnelController.profiles(installed: installed, managers: try await ours())
        }

        private static func ours() async throws -> [NETunnelProviderManager] {
            try await NETunnelProviderManager.loadAllFromPreferences().filter(\.isOurs)
        }

        /// Registers the profile on first use, so installing a configuration
        /// and `up` are the only steps. The start also activates the embedded
        /// system extension, which replaces an installed older build while the
        /// tunnel is down. The first run asks the user to allow the extension
        /// and VPN configurations.
        static func up(_ name: String, needsApproval: @escaping @Sendable () -> Void) async throws {
            guard ProfileName.isValid(name) else {
                throw TunnelController.Failure(errorDescription: "invalid profile name \(name)")
            }
            // Registering a manager and starting it both need the current
            // extension present, and waiting for approval here holds no
            // transition slot.
            try await SystemExtension.activate(needsApproval: needsApproval)
            let managers = try await ours()
            let manager = managers.first { $0.name == name } ?? NETunnelProviderManager()
            try await TunnelController.register(manager, name: name)
            // A freshly saved manager cannot start until it is loaded again.
            try await manager.loadFromPreferences()
            try await TunnelController.up(manager, managers: managers)
        }

        static func registered(_ name: String) async throws -> NETunnelProviderManager {
            guard let manager = try await ours().first(where: { $0.name == name }) else {
                throw TunnelController.Failure(errorDescription: "\(name) is not registered, run up first")
            }
            return manager
        }

        /// The connected profile used by the shared show, ip, and ping
        /// commands.
        static func active() async throws -> NETunnelProviderManager {
            guard let manager = try await ours().first(where: { $0.status == .connected }) else {
                throw TunnelController.Failure(errorDescription: "no profile is connected")
            }
            return manager
        }
    }

#else

    /// iOS profiles are the NetworkExtension configurations whose keychain item
    /// still resolves.
    @MainActor
    enum ImportedProfiles {
        private static let repository = ProfileRepository(
            storage: .init(
                load: {
                    try await NETunnelProviderManager.loadAllFromPreferences().map {
                        .init(manager: $0, reference: $0.protocolConfiguration?.passwordReference)
                    }
                },
                read: ProfileStore.read,
                references: ProfileStore.references,
                create: ProfileStore.add,
                save: { name, reference in
                    try await TunnelController.register(NETunnelProviderManager(), name: name) {
                        $0.passwordReference = reference
                    }
                },
                delete: ProfileStore.delete))

        static func all() async throws -> [TunnelController.Profile] {
            try await repository.all()
        }

        static func up(_ selected: TunnelManager) async throws {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            // loadAll creates new manager objects. The keychain persistent
            // reference identifies the selected iOS profile even when display
            // names collide.
            guard let reference = (selected as? NETunnelProviderManager)?.protocolConfiguration?.passwordReference,
                let target = managers.first(where: {
                    $0.isOurs && $0.protocolConfiguration?.passwordReference == reference
                })
            else {
                throw TunnelController.Failure(errorDescription: "profile is no longer registered")
            }
            try await TunnelController.up(target, managers: managers)
        }

        /// The text is not checked here: the app links no engine, so a bad
        /// configuration is the provider's error on the first connect. Saving
        /// asks the user to allow VPN configurations.
        static func add(_ name: String, text: String) async throws {
            try await repository.add(name, text: text)
        }
    }

    extension TunnelController.Profile {
        /// Listing only returns managers with a readable persistent keychain
        /// reference.
        var keychainReference: Data {
            (manager as! NETunnelProviderManager).protocolConfiguration!.passwordReference!
        }
    }

#endif
