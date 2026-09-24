import XCTest

@MainActor
private final class ProfileStorageFake {
    var entries: [ProfileRepository.Entry] = []
    var items: [Data: String] = [:]
    var created = 0
    var deleted: [Data] = []
    var reads: [Data?] = []
    var readError: Error?
    var enumerationError: Error?
    var saveError: Error?
    var deleteError: Error?
    var saving: (() async -> Void)?

    func repository() -> ProfileRepository {
        ProfileRepository(
            storage: .init(
                load: { self.entries.filter { ($0.manager as! FakeManager).removed == 0 } },
                read: {
                    self.reads.append($0)
                    if let error = self.readError { throw error }
                    return $0.flatMap { self.items[$0] }
                },
                references: {
                    if let error = self.enumerationError { throw error }
                    return Set(self.items.keys)
                },
                create: { _, text in
                    self.created += 1
                    let reference = Data("new-\(self.created)".utf8)
                    self.items[reference] = text
                    return reference
                },
                save: { name, reference in
                    await self.saving?()
                    if let error = self.saveError { throw error }
                    self.entries.append(.init(manager: FakeManager(name), reference: reference))
                },
                delete: {
                    if let error = self.deleteError { throw error }
                    self.deleted.append($0)
                    self.items.removeValue(forKey: $0)
                }))
    }

    @discardableResult
    func insert(_ name: String, reference: String, present: Bool = true) -> FakeManager {
        let manager = FakeManager(name)
        let ref = Data(reference.utf8)
        entries.append(.init(manager: manager, reference: ref))
        if present { items[ref] = "configuration" }
        return manager
    }
}

@MainActor
final class ProfileRepositoryTests: XCTestCase {
    /// An import of "home" whose save is suspended until the continuation
    /// resumes.
    private func suspendedImport(_ store: ProfileStorageFake, _ repository: ProfileRepository) async -> (
        Task<Void, Error>, CheckedContinuation<Void, Never>
    ) {
        let saving = expectation(description: "save suspended")
        var resume: CheckedContinuation<Void, Never>!
        store.saving = {
            await withCheckedContinuation {
                resume = $0
                saving.fulfill()
            }
        }
        let importing = Task { try await repository.add("home", text: "secret") }
        await fulfillment(of: [saving], timeout: 2)
        return (importing, resume)
    }

    /// The operation as a task that has begun, so it is queued behind the
    /// repository's current work.
    private func queued<T>(_ operation: @escaping @MainActor () async throws -> T) async -> Task<T, Error> {
        let begun = expectation(description: "queued")
        let task = Task {
            begun.fulfill()
            return try await operation()
        }
        await fulfillment(of: [begun], timeout: 2)
        return task
    }

    func testListingAndDuplicateImportWaitForSuspendedSave() async throws {
        let store = ProfileStorageFake()
        let repository = store.repository()
        let (first, resume) = await suspendedImport(store, repository)
        var listed = false
        let listing = await queued {
            let profiles = try await repository.all()
            listed = true
            return profiles
        }
        let duplicate = await queued { try await repository.add("home", text: "other") }
        XCTAssertFalse(listed)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(store.deleted.isEmpty)
        resume.resume()
        try await first.value
        let profiles = try await listing.value
        XCTAssertEqual(profiles.map(\.name), ["home"])
        let error = await thrown { try await duplicate.value }
        XCTAssertEqual(error?.localizedDescription, "a profile named home already exists")
        XCTAssertEqual(store.created, 1)
        XCTAssertTrue(store.deleted.isEmpty)
    }

    func testInvalidNameIsRejectedBeforeAnyStorage() async {
        let store = ProfileStorageFake()
        let error = await thrown { try await store.repository().add("a/b", text: "secret") }
        XCTAssertEqual(error?.localizedDescription, "use letters, digits, - and _ in the name")
        XCTAssertEqual(store.created, 0)
    }

    func testSaveFailureRollsBackOnlyItsOwnItemAndQueueRecovers() async throws {
        let store = ProfileStorageFake()
        store.insert("old", reference: "old")
        store.saveError = failure("save failed")
        let repository = store.repository()
        let error = await thrown { try await repository.add("new", text: "secret") }
        XCTAssertEqual(error?.localizedDescription, "save failed")
        XCTAssertEqual(Set(store.items.keys), [Data("old".utf8)])
        XCTAssertEqual(store.deleted, [Data("new-1".utf8)])
        store.saveError = nil
        try await repository.add("new", text: "secret")
        let profiles = try await repository.all()
        XCTAssertEqual(profiles.map(\.name), ["new", "old"])
    }

    func testRollbackFailureReportsBothErrorsAndNextReconciliationRemovesOrphan() async throws {
        let store = ProfileStorageFake()
        store.saveError = failure("save failed")
        store.deleteError = failure("delete failed")
        let repository = store.repository()
        let error = await thrown { try await repository.add("new", text: "secret") }
        XCTAssertEqual(error?.localizedDescription, "save failed, keychain rollback failed: delete failed")
        XCTAssertEqual(store.items.count, 1)
        store.deleteError = nil
        let profiles = try await repository.all()
        XCTAssertTrue(profiles.isEmpty)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testKeychainFailuresPreventAllCleanup() async {
        for enumeration in [false, true] {
            let store = ProfileStorageFake()
            let stale = store.insert("stale", reference: "absent", present: false)
            store.insert("live", reference: "live")
            store.items[Data("orphan".utf8)] = "secret"
            if enumeration { store.enumerationError = failure("locked") } else { store.readError = failure("locked") }
            let error = await thrown { _ = try await store.repository().all() }
            XCTAssertEqual(error?.localizedDescription, "locked")
            XCTAssertEqual(stale.removed, 0)
            XCTAssertTrue(store.deleted.isEmpty)
            XCTAssertEqual(store.items.count, 2)
        }
    }

    func testPruningFailureIsVisible() async {
        let store = ProfileStorageFake()
        store.items[Data("orphan".utf8)] = "secret"
        store.deleteError = failure("delete failed")
        let error = await thrown { _ = try await store.repository().all() }
        XCTAssertEqual(error?.localizedDescription, "delete failed")
        XCTAssertEqual(store.items.count, 1)
    }

    func testCanceledSaveRollsBackBeforeNextListing() async throws {
        let store = ProfileStorageFake()
        let repository = store.repository()
        store.saveError = CancellationError()
        let (importing, resume) = await suspendedImport(store, repository)
        importing.cancel()
        let listing = Task { try await repository.all() }
        XCTAssertEqual(store.items.count, 1)
        resume.resume()
        let error = await thrown { try await importing.value }
        XCTAssertTrue(error is CancellationError)
        let profiles = try await listing.value
        XCTAssertTrue(profiles.isEmpty)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.deleted, [Data("new-1".utf8)])
    }

    func testReconciliationUsesReferencesAndIgnoresForeignManagers() async throws {
        let store = ProfileStorageFake()
        let first = store.insert("same", reference: "a")
        let second = store.insert("same", reference: "b")
        let stale = store.insert("same", reference: "missing", present: false)
        let foreign = store.insert("foreign", reference: "foreign", present: false)
        foreign.providerBundleIdentifier = "other.provider"
        let profiles = try await store.repository().all()
        XCTAssertEqual(profiles.map(\.name), ["same", "same"])
        XCTAssertTrue(profiles.contains { $0.manager === first })
        XCTAssertTrue(profiles.contains { $0.manager === second })
        XCTAssertEqual(stale.removed, 1)
        XCTAssertEqual(foreign.removed, 0)
        XCTAssertFalse(store.reads.contains(Data("foreign".utf8)))
        XCTAssertEqual(Set(store.items.keys), [Data("a".utf8), Data("b".utf8)])
    }

    func testRestartPrunesOrphanButKeepsCommittedProfile() async throws {
        let store = ProfileStorageFake()
        store.insert("saved", reference: "saved")
        store.items[Data("interrupted-import".utf8)] = "secret"
        let profiles = try await store.repository().all()
        XCTAssertEqual(profiles.map(\.name), ["saved"])
        XCTAssertEqual(store.deleted, [Data("interrupted-import".utf8)])
    }

    func testManagerRemovalFailurePreventsPruning() async {
        let store = ProfileStorageFake()
        store.insert("stale", reference: "missing", present: false).removalError = failure("remove failed")
        store.items[Data("orphan".utf8)] = "secret"
        let error = await thrown { _ = try await store.repository().all() }
        XCTAssertEqual(error?.localizedDescription, "remove failed")
        XCTAssertTrue(store.deleted.isEmpty)
    }

    func testCancellationRetainsOwnershipUntilSaveFinishesAndSkipsQueuedImport() async throws {
        let store = ProfileStorageFake()
        let repository = store.repository()
        let (first, resume) = await suspendedImport(store, repository)
        first.cancel()
        let canceled = await queued { try await repository.add("canceled", text: "secret") }
        canceled.cancel()
        XCTAssertEqual(store.created, 1)
        XCTAssertTrue(store.deleted.isEmpty)
        resume.resume()
        try await first.value
        let error = await thrown { try await canceled.value }
        XCTAssertTrue(error is CancellationError)
        let profiles = try await repository.all()
        XCTAssertEqual(profiles.map(\.name), ["home"])
        XCTAssertEqual(store.created, 1)
    }
}
