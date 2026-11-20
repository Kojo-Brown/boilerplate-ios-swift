import Foundation
import SwiftData
import Testing
@testable import Core

// MARK: - The two implementations under contract

/// Which `UserPersistenceService` a contract case is running against.
///
/// As with `RepositoryUnderContract`, the case bodies cannot tell which side
/// they have. That is the whole mechanism: a sentence about the store that
/// holds for one implementation and not the other fails here instead of
/// becoming a test suite that is green against a store the app never has.
enum StoreUnderContract: String, CaseIterable, Sendable {
    /// `SwiftDataUserPersistenceService` over an in-memory `ModelContainer`,
    /// built exactly the way `AppContainer` builds the on-disk one.
    case liveSwiftData

    /// The hand-written double from `Sources/`, which is what the view-model
    /// suites and every SwiftUI preview run against.
    case handWrittenDouble
}

// MARK: - Fixtures

/// Whole seconds, and distinct ones.
///
/// `fetchCurrentRecord()` orders rows by `createdAt` and treats `nil` as
/// `.distantPast`, so the two timestamps below have to be far enough apart that
/// the ordering case is asserting the rule rather than a clock.
private let earlier = Date(timeIntervalSince1970: 1_700_000_000)
private let later = Date(timeIntervalSince1970: 1_700_086_400)
private let confirmedAt = Date(timeIntervalSince1970: 1_700_090_000)

private func makeUser(
    name: String = "Contract User",
    email: String = "store@example.invalid",
    createdAt: Date? = earlier
) -> User {
    User(
        email: email,
        name: name,
        avatarURL: URL(string: "https://avatars.example.invalid/store.png"),
        createdAt: createdAt,
        updatedAt: earlier,
        version: 3
    )
}

// MARK: - The contract

/// The contract `UserPersistenceService` states, run against both
/// implementations.
///
/// This is the seam `docs/solid.md` finding 3 was found in, and the shape of
/// that finding is the argument for this file. `save(user:)` inserted in the
/// real store and upserted in the double; saving one user twice therefore left
/// two rows on device and one entry under test, and `fetchCurrentUser()` chose
/// between the two rows on `max(by:)`'s unspecified tie-break. Nothing failed.
/// The repair came with a pin — `saveAgreesBetweenImplementations` — covering
/// one method of the nine, which is the state of affairs this item changes: the
/// nine are below, each asserted against both sides.
///
/// Three things are deliberately **not** asserted here, because they are not
/// contract:
///
/// * **The row count.** Nothing on the protocol can count rows, so "saving
///   twice leaves one row" is observable only behind it — which is what
///   `saveAgreesBetweenImplementations` reaches through `container.mainContext`
///   and the double's `storage` to do. What the contract asserts instead is the
///   consequence: the read after two saves is the second value, deterministically.
/// * **The tie-break between two rows with the same `createdAt`.** Both
///   implementations leave it to `max(by:)` over a sequence whose order neither
///   specifies. A case asserting either answer would be pinning an accident.
/// * **The call counts.** `MockUserPersistenceService` records them and the real
///   store cannot. They are a property of the double, tested where they are
///   used.
///
/// `.serialized` and the stored container follow `UserPersistenceTests`: a
/// `ModelContext` does not keep its `ModelContainer` alive, and a container
/// built inside a helper is deallocated before the test body runs, which
/// SwiftData reports by trapping and taking the whole test process with it.
@Suite("UserPersistenceService contract", .serialized)
@MainActor
struct UserPersistenceContractTests {

    private let container: ModelContainer
    private let live: SwiftDataUserPersistenceService
    private let double: MockUserPersistenceService

    init() throws {
        container = try PersistenceController.makeInMemoryContainer()
        live = SwiftDataUserPersistenceService(context: container.mainContext)
        double = MockUserPersistenceService()
    }

    private func store(_ kind: StoreUnderContract) -> any UserPersistenceService {
        switch kind {
        case .liveSwiftData: return live
        case .handWrittenDouble: return double
        }
    }

    // MARK: - Reads on an empty store

    @Test("An empty store answers nil, not an error", arguments: StoreUnderContract.allCases)
    func emptyStoreAnswersNil(_ kind: StoreUnderContract) async throws {
        let subject = store(kind)

        let user = try await subject.fetchCurrentUser()
        let current = try await subject.fetchCurrentRecord()
        let byId = try await subject.fetchRecord(userId: UUID())

        #expect(user == nil)
        #expect(current == nil)
        #expect(byId == nil)
    }

    @Test("A record lookup for an unknown id is nil", arguments: StoreUnderContract.allCases)
    func unknownRecordIsNil(_ kind: StoreUnderContract) async throws {
        let subject = store(kind)
        try await subject.save(user: makeUser())

        let byId = try await subject.fetchRecord(userId: UUID())
        #expect(byId == nil)
    }

    // MARK: - save

    /// Every mapped field, both ways through the store.
    ///
    /// The live side goes through `User.toEntity()` and `toDomainUser()`, so a
    /// field added to `User` and forgotten in one of those two mappings fails
    /// here — against the double, which keeps the whole value, it never would.
    @Test("A saved user reads back whole", arguments: StoreUnderContract.allCases)
    func savedUserReadsBackWhole(_ kind: StoreUnderContract) async throws {
        let subject = store(kind)
        let user = makeUser()

        try await subject.save(user: user)
        let fetched = try #require(await subject.fetchCurrentUser())

        #expect(fetched == user)
    }

    @Test("Saving the same identity twice replaces it", arguments: StoreUnderContract.allCases)
    func savingTwiceReplaces(_ kind: StoreUnderContract) async throws {
        let subject = store(kind)
        let user = makeUser()

        try await subject.save(user: user)
        try await subject.save(user: user.with(name: .set("Second")))
        let fetched = try #require(await subject.fetchCurrentUser())

        #expect(fetched.id == user.id)
        #expect(fetched.name == "Second")
    }

    @Test("A save with a stamp records it", arguments: StoreUnderContract.allCases)
    func saveWithAStampRecordsIt(_ kind: StoreUnderContract) async throws {
        let subject = store(kind)
        let user = makeUser()

        try await subject.save(user: user, refreshedAt: confirmedAt)
        let record = try #require(await subject.fetchCurrentRecord())

        #expect(record.user == user)
        #expect(record.refreshedAt == confirmedAt)
    }

    /// The protocol's sharpest clause, and the one a reader is most likely to
    /// get wrong: a save that heard nothing from the API *clears* an existing
    /// stamp rather than leaving it, because a stamp that outlives the value it
    /// described is worse than no stamp at all.
    @Test("A save without a stamp clears the one that was there", arguments: StoreUnderContract.allCases)
    func saveWithoutAStampClearsIt(_ kind: StoreUnderContract) async throws {
        let subject = store(kind)
        let user = makeUser()

        try await subject.save(user: user, refreshedAt: confirmedAt)
        try await subject.save(user: user)
        let record = try #require(await subject.fetchCurrentRecord())

        #expect(record.refreshedAt == nil)
    }

    // MARK: - fetch

    @Test("The current user is the current record's user", arguments: StoreUnderContract.allCases)
    func currentUserAgreesWithCurrentRecord(_ kind: StoreUnderContract) async throws {
        let subject = store(kind)
        try await subject.save(user: makeUser(), refreshedAt: confirmedAt)

        let user = try await subject.fetchCurrentUser()
        let record = try await subject.fetchCurrentRecord()

        #expect(user == record?.user)
    }

    @Test("The current record is the one created most recently", arguments: StoreUnderContract.allCases)
    func currentRecordIsTheNewest(_ kind: StoreUnderContract) async throws {
        let subject = store(kind)
        let older = makeUser(name: "Older", email: "older@example.invalid", createdAt: earlier)
        let newer = makeUser(name: "Newer", email: "newer@example.invalid", createdAt: later)

        try await subject.save(user: older)
        try await subject.save(user: newer)

        let current = try await subject.fetchCurrentUser()
        #expect(current?.id == newer.id)
    }

    /// `createdAt` is optional because the API genuinely may omit it, and both
    /// implementations order a row without one as the oldest rather than as the
    /// newest. Reversing that would make a seeded row win every read.
    @Test("A row with no creation date is the oldest", arguments: StoreUnderContract.allCases)
    func missingCreationDateSortsOldest(_ kind: StoreUnderContract) async throws {
        let subject = store(kind)
        let undated = makeUser(name: "Undated", email: "undated@example.invalid", createdAt: nil)
        let dated = makeUser(name: "Dated", email: "dated@example.invalid", createdAt: earlier)

        try await subject.save(user: undated)
        try await subject.save(user: dated)

        let current = try await subject.fetchCurrentUser()
        #expect(current?.id == dated.id)
    }

    /// The read a write-then-return needs: it names the row it just wrote,
    /// rather than asking "who is current" and being answered about another
    /// account's.
    @Test("A record lookup answers about the id it was given", arguments: StoreUnderContract.allCases)
    func recordLookupAnswersAboutItsId(_ kind: StoreUnderContract) async throws {
        let subject = store(kind)
        let older = makeUser(name: "Older", email: "older@example.invalid", createdAt: earlier)
        let newer = makeUser(name: "Newer", email: "newer@example.invalid", createdAt: later)

        try await subject.save(user: older, refreshedAt: confirmedAt)
        try await subject.save(user: newer)
        let record = try #require(await subject.fetchRecord(userId: older.id))

        #expect(record.user == older)
        #expect(record.refreshedAt == confirmedAt)
    }

    // MARK: - update

    @Test("An update replaces every mapped field", arguments: StoreUnderContract.allCases)
    func updateReplacesEveryField(_ kind: StoreUnderContract) async throws {
        let subject = store(kind)
        let user = makeUser()
        try await subject.save(user: user)

        let edited = user.with(
            name: .set("Edited"),
            avatarURL: .set(URL(string: "https://avatars.example.invalid/edited.png")),
            updatedAt: .set(later),
            version: .set(4)
        )
        try await subject.update(user: edited)
        let fetched = try #require(await subject.fetchCurrentUser())

        #expect(fetched == edited)
    }

    /// An update says what the row contains; only a save gets to claim the API
    /// confirmed it.
    @Test("An update leaves the confirmation stamp alone", arguments: StoreUnderContract.allCases)
    func updateLeavesTheStampAlone(_ kind: StoreUnderContract) async throws {
        let subject = store(kind)
        let user = makeUser()
        try await subject.save(user: user, refreshedAt: confirmedAt)

        try await subject.update(user: user.with(name: .set("Edited")))
        let record = try #require(await subject.fetchCurrentRecord())

        #expect(record.user.name == "Edited")
        #expect(record.refreshedAt == confirmedAt)
    }

    @Test("An update of a row that is not there is userNotFound", arguments: StoreUnderContract.allCases)
    func updateOfAMissingRowThrows(_ kind: StoreUnderContract) async throws {
        let subject = store(kind)

        do {
            try await subject.update(user: makeUser())
            Issue.record("updating a row that is not there should have thrown")
        } catch let error as PersistenceError {
            #expect(error == .userNotFound)
        }
    }

    // MARK: - delete

    @Test("A delete removes the row and its stamp", arguments: StoreUnderContract.allCases)
    func deleteRemovesTheRowAndItsStamp(_ kind: StoreUnderContract) async throws {
        let subject = store(kind)
        let user = makeUser()
        try await subject.save(user: user, refreshedAt: confirmedAt)

        try await subject.delete(userId: user.id)

        let byId = try await subject.fetchRecord(userId: user.id)
        let current = try await subject.fetchCurrentRecord()
        #expect(byId == nil)
        #expect(current == nil)
    }

    @Test("A delete of a row that is not there is userNotFound", arguments: StoreUnderContract.allCases)
    func deleteOfAMissingRowThrows(_ kind: StoreUnderContract) async throws {
        let subject = store(kind)

        do {
            try await subject.delete(userId: UUID())
            Issue.record("deleting a row that is not there should have thrown")
        } catch let error as PersistenceError {
            #expect(error == .userNotFound)
        }
    }

    @Test("deleteAll empties the store and throws for nothing", arguments: StoreUnderContract.allCases)
    func deleteAllEmptiesTheStore(_ kind: StoreUnderContract) async throws {
        let subject = store(kind)
        try await subject.save(user: makeUser(email: "one@example.invalid"), refreshedAt: confirmedAt)
        try await subject.save(user: makeUser(email: "two@example.invalid"))

        try await subject.deleteAll()
        let current = try await subject.fetchCurrentRecord()
        #expect(current == nil)

        // Empty already: `deleteAll` is the one removal on this protocol that is
        // not a claim that something was there.
        try await subject.deleteAll()
    }
}
