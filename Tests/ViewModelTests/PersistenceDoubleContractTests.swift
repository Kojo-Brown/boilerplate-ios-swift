import Foundation
import SwiftData
import Testing
@testable import Core

// MARK: - The two implementations, as a test argument

/// Phase 12 item 5. Which `UserPersistenceService` a case runs against.
///
/// Every test below is `@Test(arguments: ContractStoreKind.allCases)`, so each one runs
/// twice and the test name in the report says which half failed. A `for` loop
/// over the two would report one failure for the pair and stop at the first,
/// which is the wrong shape for a differential test: the interesting outcome is
/// "the live store does this and the double does that", and that needs both
/// halves to run and be named.
/// Internal rather than `private`, which is not a style choice: a `@Test`
/// method is internal, and Swift refuses an internal method whose parameter
/// uses a private type. `PinningFixture` is internal for the same reason.
enum ContractStoreKind: String, CaseIterable, Sendable, CustomTestStringConvertible {

    /// `SwiftDataUserPersistenceService` over an in-memory `ModelContainer` —
    /// real SwiftData, real `ModelContext`, real fetches, no file on disk.
    case live

    /// `MockUserPersistenceService`, the hand-written protocol fake.
    case double

    var testDescription: String { rawValue }
}

/// The store a case runs against, behind the protocol a caller would hold.
///
/// Nothing holds the live container alongside it, and nothing needs to:
/// `ModelContext` keeps a strong reference to its own `ModelContainer`, so the
/// container lives exactly as long as the store built from its context.
/// `SolidSubstitutabilityTests` holds one as a property because it executes a
/// `FetchDescriptor` of its own, which is the thing this suite deliberately
/// never does.
@MainActor
private func makeStore(_ kind: ContractStoreKind) throws -> any UserPersistenceService {
    switch kind {
    case .live:
        let container = try PersistenceController.makeInMemoryContainer()
        return SwiftDataUserPersistenceService(context: container.mainContext)
    case .double:
        return MockUserPersistenceService()
    }
}

// MARK: - Fixtures

private let contractUserID = UUID(uuidString: "00000000-0000-0000-0000-00000000ACE1")!
private let otherUserID = UUID(uuidString: "00000000-0000-0000-0000-00000000BEEF")!

/// Fixed instants rather than `Date()`, so a failure is reproducible and the
/// ordering assertions do not depend on how fast the test ran.
private let confirmedAt = Date(timeIntervalSince1970: 1_650_000_000)
private let newerInstant = Date(timeIntervalSince1970: 1_700_000_000)
private let olderInstant = Date(timeIntervalSince1970: 1_600_000_000)

private func makeUser(
    id: UUID = contractUserID,
    name: String = "Contract",
    createdAt: Date? = nil
) -> User {
    User(
        id: id,
        email: "contract@example.invalid",
        name: name,
        createdAt: createdAt
    )
}

/// Dates survive SwiftData as a stored `Double`, so a round trip is compared
/// with a tolerance rather than for identity. A millisecond is far tighter than
/// any staleness decision this stamp feeds — `StoredUser.isFresh(at:maxAge:)`
/// deals in minutes — and far looser than the representation error.
private func expectSameInstant(_ actual: Date?, _ expected: Date, _ label: String) {
    guard let actual else {
        Issue.record("\(label): expected a confirmation stamp, got nil")
        return
    }
    #expect(abs(actual.timeIntervalSince(expected)) < 0.001, "\(label)")
}

// MARK: - The contract

/// The behaviour `MockUserPersistenceService` promises by conforming, asserted
/// against the store it replaces.
///
/// ## Why this is not more `UserPersistenceTests`
///
/// `UserPersistenceTests` and `SolidSubstitutabilityTests` between them already
/// exercise both implementations, and that is exactly the gap this closes: they
/// exercise them *separately*. A suite that drives the double and a suite that
/// drives the store can both be green while the two disagree, and a test using
/// the double is then evidence about the double rather than about the app. The
/// one place the two were pinned against each other before this item was
/// `saveAgreesBetweenImplementations`, which covers the `save` upsert and
/// nothing else — the other eight requirements on the protocol were a matter of
/// having been written twice and read once.
///
/// Every assertion here goes through `any UserPersistenceService`. Nothing
/// reaches for `MockUserPersistenceService.storage` or executes a
/// `FetchDescriptor`, because a contract is what a *caller* can observe, and a
/// caller holds the protocol. That is also what makes each case run unchanged
/// against both halves.
///
/// Each case builds its own store, so the in-memory container starts empty and
/// the suite needs no `.serialized` and no teardown.
@Suite("Double contract — persistence")
@MainActor
struct PersistenceDoubleContractTests {

    @Test("An empty store answers nil rather than throwing", arguments: ContractStoreKind.allCases)
    func anEmptyStoreIsEmpty(kind: ContractStoreKind) async throws {
        let store = try makeStore(kind)

        let user = try await store.fetchCurrentUser()
        let current = try await store.fetchCurrentRecord()
        let named = try await store.fetchRecord(userId: contractUserID)

        #expect(user == nil)
        #expect(current == nil)
        #expect(named == nil)
    }

    /// The upsert, observed through the protocol rather than by counting rows.
    ///
    /// `saveAgreesBetweenImplementations` counts rows, which it can only do by
    /// reaching past the seam into a `FetchDescriptor` on one side and a
    /// dictionary on the other. A caller cannot do either. What a caller can do
    /// is delete once and look again: a store that inserted twice still holds
    /// the second row after one `delete`, because `delete` removes the row it
    /// matched and not every row carrying that identity.
    @Test("Saving the same identity twice leaves one row", arguments: ContractStoreKind.allCases)
    func saveUpsertsRatherThanInserting(kind: ContractStoreKind) async throws {
        let store = try makeStore(kind)

        try await store.save(user: makeUser(name: "First"))
        try await store.save(user: makeUser(name: "Second"))

        let record = try await store.fetchRecord(userId: contractUserID)
        #expect(record?.user.name == "Second")

        try await store.delete(userId: contractUserID)
        let afterDelete = try await store.fetchCurrentUser()
        #expect(afterDelete == nil)
    }

    @Test("A save that heard from the API records when", arguments: ContractStoreKind.allCases)
    func saveRecordsTheConfirmation(kind: ContractStoreKind) async throws {
        let store = try makeStore(kind)

        try await store.save(user: makeUser(), refreshedAt: confirmedAt)

        let named = try await store.fetchRecord(userId: contractUserID)
        let record = try #require(named)
        expectSameInstant(record.refreshedAt, confirmedAt, "\(kind.rawValue)/fetchRecord")

        let fetched = try await store.fetchCurrentRecord()
        let current = try #require(fetched)
        expectSameInstant(current.refreshedAt, confirmedAt, "\(kind.rawValue)/fetchCurrentRecord")
    }

    /// The clearing behaviour the protocol specifies, and the one most likely
    /// to be got wrong by a double written to make a test pass: leaving the old
    /// stamp is a one-line difference, and it produces a row that claims the
    /// server confirmed a value the server never saw.
    @Test("A bare save clears an existing confirmation", arguments: ContractStoreKind.allCases)
    func bareSaveClearsTheConfirmation(kind: ContractStoreKind) async throws {
        let store = try makeStore(kind)

        try await store.save(user: makeUser(), refreshedAt: confirmedAt)
        try await store.save(user: makeUser(name: "Written locally"))

        let named = try await store.fetchRecord(userId: contractUserID)
        let record = try #require(named)
        #expect(record.user.name == "Written locally")
        #expect(record.refreshedAt == nil)
    }

    /// The mirror image: an update says what the row contains and not where it
    /// came from, so the stamp outlives it.
    @Test("An update leaves the confirmation alone", arguments: ContractStoreKind.allCases)
    func updateLeavesTheConfirmation(kind: ContractStoreKind) async throws {
        let store = try makeStore(kind)

        try await store.save(user: makeUser(), refreshedAt: confirmedAt)
        try await store.update(user: makeUser(name: "Renamed"))

        let named = try await store.fetchRecord(userId: contractUserID)
        let record = try #require(named)
        #expect(record.user.name == "Renamed")
        expectSameInstant(record.refreshedAt, confirmedAt, "\(kind.rawValue)")
    }

    @Test("Updating a row that is not there is userNotFound", arguments: ContractStoreKind.allCases)
    func updatingAnAbsentRowThrows(kind: ContractStoreKind) async throws {
        let store = try makeStore(kind)

        await #expect(throws: PersistenceError.userNotFound) {
            try await store.update(user: makeUser())
        }
    }

    @Test("Deleting a row that is not there is userNotFound", arguments: ContractStoreKind.allCases)
    func deletingAnAbsentRowThrows(kind: ContractStoreKind) async throws {
        let store = try makeStore(kind)

        await #expect(throws: PersistenceError.userNotFound) {
            try await store.delete(userId: contractUserID)
        }
    }

    @Test("deleteAll empties the store, and an empty one is not an error", arguments: ContractStoreKind.allCases)
    func deleteAllEmptiesTheStore(kind: ContractStoreKind) async throws {
        let store = try makeStore(kind)

        try await store.deleteAll()

        try await store.save(user: makeUser())
        try await store.save(user: makeUser(id: otherUserID, name: "Other"))
        try await store.deleteAll()

        let current = try await store.fetchCurrentUser()
        let first = try await store.fetchRecord(userId: contractUserID)
        let second = try await store.fetchRecord(userId: otherUserID)

        #expect(current == nil)
        #expect(first == nil)
        #expect(second == nil)
    }

    /// "Who is current" is answered by the greatest `createdAt`, with `nil`
    /// treated as oldest — the ordering both implementations had to be taught
    /// by hand, because the store cannot express it. SwiftData traps on a
    /// `SortDescriptor` over an optional key path, so the live store sorts in
    /// memory; the double sorts a dictionary's values. Two hand-written
    /// orderings is precisely the shape of thing that drifts.
    ///
    /// The dated row is saved *first* so that insertion order and the correct
    /// answer disagree. A store that returned "the last one written" would pass
    /// a version of this test that saved them the other way round.
    @Test("The current row is the one with the greatest createdAt", arguments: ContractStoreKind.allCases)
    func theCurrentRowIsTheNewest(kind: ContractStoreKind) async throws {
        let store = try makeStore(kind)

        try await store.save(user: makeUser(name: "Newest", createdAt: newerInstant))
        try await store.save(user: makeUser(id: otherUserID, name: "Undated", createdAt: nil))

        let current = try await store.fetchCurrentUser()
        #expect(current?.name == "Newest")
    }

    /// `fetchRecord(userId:)` exists because `fetchCurrentRecord()` answers a
    /// different question, and a write-then-read-back that used the latter
    /// could be handed another account's row.
    @Test("fetchRecord answers about the row named, not the current one", arguments: ContractStoreKind.allCases)
    func fetchRecordAnswersAboutTheRowNamed(kind: ContractStoreKind) async throws {
        let store = try makeStore(kind)

        try await store.save(user: makeUser(name: "Newest", createdAt: newerInstant))
        try await store.save(user: makeUser(id: otherUserID, name: "Older", createdAt: olderInstant))

        let current = try await store.fetchCurrentUser()
        let named = try await store.fetchRecord(userId: otherUserID)

        #expect(current?.name == "Newest")
        #expect(named?.user.name == "Older")
    }

    /// `fetchCurrentUser()` is spelled in terms of `fetchCurrentRecord()` in
    /// both implementations, so the two can never answer about different rows.
    /// This is the pin for that: it is a one-line change in either to make them
    /// disagree, and nothing else would notice.
    @Test("fetchCurrentUser is the row half of fetchCurrentRecord", arguments: ContractStoreKind.allCases)
    func theTwoCurrentReadsAgree(kind: ContractStoreKind) async throws {
        let store = try makeStore(kind)
        try await store.save(user: makeUser(), refreshedAt: confirmedAt)

        let user = try await store.fetchCurrentUser()
        let record = try await store.fetchCurrentRecord()

        #expect(user == record?.user)
    }
}
