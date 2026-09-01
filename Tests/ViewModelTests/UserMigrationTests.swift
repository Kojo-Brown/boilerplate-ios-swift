import Foundation
import SwiftData
import Testing
@testable import Core

// MARK: - Schema migration

/// Proves the app can open the stores it has already shipped.
///
/// Every other persistence suite runs on `makeInMemoryContainer()`, which is
/// created empty at the current version on every call — so none of them can
/// fail when a migration is wrong, because none of them ever has an older store
/// to migrate. These tests write a real store to a temporary file in an old
/// shape and then open it the way the app does, through
/// `PersistenceController`, which is the only arrangement where the migration
/// plan does any work at all.
///
/// `.serialized`, and a fresh directory per test, because these are file-backed
/// containers: two of them opening the same URL at once is not what is under
/// test, and a leftover store from a previous test would be a migration the
/// test did not ask for.
@Suite(.serialized)
@MainActor
struct UserMigrationTests {

    // MARK: - V1 → current

    @Test func aVersionOneStoreOpensWithNilInTheColumnsItNeverHad() throws {
        let identifier = UUID()
        let created = Date(timeIntervalSince1970: 1_700_000_000)

        try withTemporaryStore { url in
            try seedVersionOne(at: url, rows: [
                UserSchemaV1.UserEntity(
                    id: identifier,
                    email: "v1@example.test",
                    name: "Version One",
                    createdAt: created
                ),
            ])

            let records = try migratedRecords(at: url)
            let record = try #require(records.first)
            #expect(record.user.id == identifier)
            #expect(record.user.email == "v1@example.test")
            #expect(record.user.name == "Version One")
            #expect(record.user.createdAt == created)
            // The two attributes added since V1. `nil` is the answer both mean:
            // this row was never confirmed against the API, and it carries no
            // server revision — not "confirmed at epoch" and not "revision 0".
            #expect(record.refreshedAt == nil)
            #expect(record.user.version == nil)
        }
    }

    @Test func everyVersionOneRowSurvivesNotJustTheFirst() throws {
        try withTemporaryStore { url in
            try seedVersionOne(at: url, rows: (0..<3).map { index in
                UserSchemaV1.UserEntity(
                    id: UUID(),
                    email: "row-\(index)@example.test",
                    name: "Row \(index)"
                )
            })

            let names = try migratedRecords(at: url).map(\.user.name).sorted()
            #expect(names == ["Row 0", "Row 1", "Row 2"])
        }
    }

    // MARK: - V2 → current

    @Test func aVersionTwoStoreKeepsItsRefreshStamp() throws {
        let refreshed = Date(timeIntervalSince1970: 1_712_000_000)

        try withTemporaryStore { url in
            try seedVersionTwo(at: url, rows: [
                UserSchemaV2.UserEntity(
                    id: UUID(),
                    email: "v2@example.test",
                    name: "Version Two",
                    refreshedAt: refreshed
                ),
            ])

            let records = try migratedRecords(at: url)
            let record = try #require(records.first)
            // The stamp is what `OfflineFirstSyncStrategy` reads to decide
            // whether a launch costs a request. Losing it in a migration would
            // not fail anything loudly — it would just make the first read
            // after an upgrade hit the network, which is the bug that is
            // invisible until someone measures it.
            let drift = try #require(record.refreshedAt?.timeIntervalSince(refreshed))
            #expect(abs(drift) < 0.001)
            #expect(record.user.version == nil)
        }
    }

    // MARK: - Idempotence

    @Test func reopeningAMigratedStoreChangesNothing() throws {
        try withTemporaryStore { url in
            try seedVersionOne(at: url, rows: [
                UserSchemaV1.UserEntity(id: UUID(), email: "twice@example.test", name: "Twice"),
            ])

            let first = try migratedRecords(at: url)
            let second = try migratedRecords(at: url)
            #expect(first == second)
            #expect(second.count == 1)
        }
    }

    /// A migrated store is one the app can go on *using*, which is a stronger
    /// claim than one it can read: SwiftData will happily hand back rows from a
    /// store whose model it has not fully reconciled and then fail on the next
    /// write.
    @Test func theServiceCanWriteToAMigratedStore() throws {
        try withTemporaryStore { url in
            try seedVersionOne(at: url, rows: [
                UserSchemaV1.UserEntity(id: UUID(), email: "old@example.test", name: "Old"),
            ])

            let container = try PersistenceController.makeContainer(at: url)
            try withExtendedLifetime(container) {
                let service = SwiftDataUserPersistenceService(context: container.mainContext)
                let fresh = User(email: "new@example.test", name: "New", version: 7)
                try service.save(user: fresh, refreshedAt: Date(timeIntervalSince1970: 1_720_000_000))

                let stored = try #require(service.fetchRecord(userId: fresh.id))
                #expect(stored.user.version == 7)
                #expect(stored.refreshedAt != nil)
            }
        }
    }

    // MARK: - The plan itself

    /// The stages are a path, and a path with a gap in it is not detectable by
    /// anything except a device with an old store trying to launch.
    @Test func thePlanIsOrderedAndContiguous() {
        let versions = UserMigrationPlan.schemas.map { $0.versionIdentifier }
        #expect(versions == versions.sorted())
        #expect(Set(versions).count == versions.count)
        #expect(UserMigrationPlan.stages.count == versions.count - 1)
    }

    /// `PersistenceController` builds its container from `UserSchemaV3` and its
    /// plan from `UserMigrationPlan`. If those two ever name different versions
    /// the container throws at launch, which is a bad place to find out.
    @Test func theCurrentSchemaIsThePlansLastVersion() throws {
        let last = try #require(UserMigrationPlan.schemas.last)
        #expect(last.versionIdentifier == UserSchemaV3.versionIdentifier)
    }

    /// SwiftData persists an entity under a name taken from the class, not from
    /// the version enclosing it, and a lightweight stage maps rows across by
    /// that name. So all three versions have to describe one entity called
    /// `UserEntity` — which is a thing to assert rather than assume, because
    /// renaming the class in a new version would compile, pass every other
    /// test, and orphan every row on every device.
    @Test func everyVersionDescribesTheSameEntity() {
        let names = UserMigrationPlan.schemas.map { version in
            Schema(versionedSchema: version).entities.map(\.name).sorted()
        }
        #expect(names == [["UserEntity"], ["UserEntity"], ["UserEntity"]])
    }

    // MARK: - Helpers

    /// Runs `body` against a store URL inside a directory of its own, and
    /// removes the directory afterwards.
    ///
    /// A directory rather than a bare file because SwiftData writes three files
    /// per store (the SQLite database plus its `-wal` and `-shm` companions),
    /// and deleting only the one named here would leave the other two behind
    /// for whatever ran next.
    private func withTemporaryStore(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "user-migration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appending(path: "User.store", directoryHint: .notDirectory))
    }

    private func seedVersionOne(at url: URL, rows: [UserSchemaV1.UserEntity]) throws {
        let schema = Schema(versionedSchema: UserSchemaV1.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        try insert(rows, into: container)
    }

    private func seedVersionTwo(at url: URL, rows: [UserSchemaV2.UserEntity]) throws {
        let schema = Schema(versionedSchema: UserSchemaV2.self)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        try insert(rows, into: container)
    }

    /// The container is passed in and held across the write.
    ///
    /// A `ModelContext` does not keep its `ModelContainer` alive — see the note
    /// on `UserPersistenceTests` — and here the container is a local that
    /// nothing reads again after `mainContext`, so without
    /// `withExtendedLifetime` it is a candidate for release while the write is
    /// still using its context. SwiftData reports that by trapping, taking the
    /// whole test process with it.
    private func insert(_ rows: [some PersistentModel], into container: ModelContainer) throws {
        try withExtendedLifetime(container) {
            let context = container.mainContext
            for row in rows { context.insert(row) }
            try context.save()
        }
    }

    /// Opens the store at `url` the way the app opens its own — current schema,
    /// migration plan — and returns plain values.
    ///
    /// Values, not entities: a `PersistentModel` read out of a container that
    /// is then released is a use-after-free waiting to happen, and every
    /// assertion above outlives the container it came from. `StoredUser` is the
    /// pair the rest of the package already passes around.
    private func migratedRecords(at url: URL) throws -> [StoredUser] {
        let container = try PersistenceController.makeContainer(at: url)
        return try withExtendedLifetime(container) {
            try container.mainContext
                .fetch(FetchDescriptor<UserEntity>())
                .map { $0.toStoredUser() }
        }
    }
}
