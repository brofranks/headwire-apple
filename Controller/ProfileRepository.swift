import Foundation

/// iOS persistence, separated from Security and NetworkExtension for fault
/// injection. The queue owns each reconciliation/import across preference
/// callbacks, including rollback.
@MainActor
final class ProfileRepository {
    struct Entry {
        var manager: TunnelManager
        var reference: Data?
    }

    struct Storage {
        var load: () async throws -> [Entry]
        var read: (Data?) throws -> String?
        var references: () throws -> Set<Data>
        var create: (String, String) throws -> Data
        var save: (String, Data) async throws -> Void
        var delete: (Data) throws -> Void
    }

    private let storage: Storage
    private var tail: Task<Void, Never>?

    init(storage: Storage) { self.storage = storage }

    func all() async throws -> [TunnelController.Profile] {
        try await enqueue { try await self.reconcile() }
    }

    func add(_ name: String, text: String) async throws {
        try await enqueue {
            guard ProfileName.isValid(name) else {
                throw TunnelController.Failure(errorDescription: "use letters, digits, - and _ in the name")
            }
            // Names identify profiles in the list and the keychain.
            guard try await !self.reconcile().contains(where: { $0.name == name }) else {
                throw TunnelController.Failure(errorDescription: "a profile named \(name) already exists")
            }
            try Task.checkCancellation()
            let reference = try self.storage.create(name, text)
            do {
                try await self.storage.save(name, reference)
            } catch {
                let saveError = error
                do {
                    try self.storage.delete(reference)
                } catch {
                    throw TunnelController.Failure(
                        errorDescription:
                            "\(saveError.localizedDescription), keychain rollback failed: \(error.localizedDescription)"
                    )
                }
                throw saveError
            }
        }
    }

    private func reconcile() async throws -> [TunnelController.Profile] {
        let entries = try await storage.load().filter { $0.manager.isOurs }
        let live = try entries.filter { try storage.read($0.reference) != nil }
        // Finish every keychain read, including enumeration, before deleting
        // anything.
        let unreferenced = try storage.references().subtracting(live.compactMap(\.reference))
        try Task.checkCancellation()
        let references = Set(live.compactMap(\.reference))
        for entry in entries where entry.reference.map({ references.contains($0) }) != true {
            try await entry.manager.removeFromPreferences()
        }
        for reference in unreferenced { try storage.delete(reference) }
        return live.map {
            TunnelController.Profile(name: $0.manager.name ?? "", manager: $0.manager)
        }.sorted { $0.name < $1.name }
    }

    private func enqueue<T>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            return Isolated(value: try await operation())
        }
        // Failure belongs to the caller and must not poison subsequent queue
        // entries.
        tail = Task { _ = await task.result }
        return try await withTaskCancellationHandler {
            try await task.value.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// A queued result, which never leaves the main actor: the profile types it
/// carries hold NetworkExtension managers, which are not Sendable, and the
/// concurrency checker cannot see that both ends of the hop are isolated.
private struct Isolated<T>: @unchecked Sendable {
    let value: T
}
