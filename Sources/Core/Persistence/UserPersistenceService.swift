import SwiftData
import Foundation

// MARK: - Protocol

/// Typed CRUD surface over the SwiftData `UserEntity` model.
/// The `async` qualifier on each method lets non-`@MainActor` callers
/// cross the actor boundary with a plain `await`.
///
/// ## `save(user:)` is an upsert, on both implementations
///
/// It used to be an upsert on one of them. `docs/solid.md` finding 3: the
/// SwiftData implementation called `context.insert` while the double assigned
/// into a dictionary keyed by `user.id`, so saving the same user twice left two
/// rows on device and one entry under test — and `fetchCurrentUser()` picks the
/// greatest `createdAt`, which for two rows with the same (or `nil`) timestamp
/// is `max(by:)`'s unspecified tie-break. The audit declined to say which side
/// was right and assigned the decision here, to the item that gives this store
/// a caller that writes on every read.
///
/// The upsert wins, for the reason the audit guessed it would: this store holds
/// the signed-in user, so a second row for the same `id` is never a record, it
/// is a duplicate. `SolidSubstitutabilityTests.saveAgreesBetweenImplementations`
/// is the inverted pin.
package protocol UserPersistenceService: Sendable {

    /// Upserts `user` with no record of having heard it from the API.
    ///
    /// Equivalent to `save(user:refreshedAt: nil)`, and it *clears* an existing
    /// stamp rather than leaving it: a row a caller wrote out of its own head
    /// is not a row the server confirmed, and a stamp that outlives the value
    /// it described is worse than no stamp at all.
    func save(user: User) async throws

    /// Upserts `user` and records when the API confirmed it.
    ///
    /// The pair is one write on purpose. Storing the row and stamping it as two
    /// calls admits a state — a fresh row carrying the previous stamp, or the
    /// reverse — that a refresh policy would then read and believe.
    func save(user: User, refreshedAt: Date?) async throws

    func fetchCurrentUser() async throws -> User?

    /// The current user together with the moment that copy was confirmed.
    ///
    /// One fetch of one row, rather than `fetchCurrentUser()` followed by a
    /// second call for the stamp, which would be a torn read.
    func fetchCurrentRecord() async throws -> StoredUser?

    /// One stored user by identity, or `nil` when the store holds no such row.
    ///
    /// The read-back a write-then-return needs: it names the row it just wrote
    /// instead of asking "who is current", which is a question the store answers
    /// by `createdAt` and could answer with a different account's row.
    func fetchRecord(userId: UUID) async throws -> StoredUser?

    func update(user: User) async throws
    func delete(userId: UUID) async throws
    func deleteAll() async throws
}

// MARK: - Live implementation

/// SwiftData-backed implementation. Confined to `@MainActor` because `ModelContext`
/// is not `Sendable` and must be accessed from a single concurrency domain.
@MainActor
package final class SwiftDataUserPersistenceService: UserPersistenceService {
    private let context: ModelContext

    package init(context: ModelContext) {
        self.context = context
    }

    package func save(user: User) throws {
        try save(user: user, refreshedAt: nil)
    }

    /// Upserts, where this used to insert.
    ///
    /// The lookup is by `id` and it is what makes the write idempotent — see
    /// the protocol for why the duplicate row this replaces was a bug and not a
    /// history. `UserEntity.id` still carries no `@Attribute(.unique)`, and the
    /// comment on the model explains why it cannot: the constraint traps on an
    /// in-memory store, which is every store the tests and previews run on. So
    /// uniqueness is enforced here, by the write, rather than by the schema.
    package func save(user: User, refreshedAt: Date?) throws {
        if let existing = try entity(withID: user.id) {
            existing.overwrite(with: user)
            existing.refreshedAt = refreshedAt
        } else {
            context.insert(user.toEntity(refreshedAt: refreshedAt))
        }
        try context.save()
    }

    /// Returns the most recently created stored user, or `nil` when the store is empty.
    ///
    /// The row half of `fetchCurrentRecord()`, which is where the choice of ordering is
    /// argued. Spelled in terms of it rather than beside it, so the two can never answer
    /// about different rows.
    package func fetchCurrentUser() throws -> User? {
        try fetchCurrentRecord()?.user
    }

    /// The most recently created stored user together with its confirmation stamp.
    ///
    /// The sort is done in memory rather than by the store. `FetchDescriptor(sortBy:)`
    /// with a `SortDescriptor` over an **optional** key path — `createdAt` is `Date?` —
    /// traps inside SwiftData while executing the fetch (`EXC_BREAKPOINT`, taking the
    /// whole test process with it, not just the failing test). Making `createdAt`
    /// non-optional would fix the sort by breaking the model: the API genuinely may
    /// omit the field.
    ///
    /// Sorting here is not the compromise it looks like. This store holds the signed-in
    /// user, so the fetch is over a handful of rows at most, and `nil` has to be ordered
    /// explicitly anyway — treating it as oldest, which the database sort could not
    /// express. `MockUserPersistenceService` already ordered it exactly this way; the
    /// two implementations now agree, where before only the mock was reachable.
    ///
    /// "Most recently created" is the store's answer to "who is current", and it is a
    /// weak one while nothing clears this store on sign-out — see
    /// `docs/offline-first.md`. `fetchRecord(userId:)` is what a caller that already
    /// knows which row it means should use.
    package func fetchCurrentRecord() throws -> StoredUser? {
        try context.fetch(FetchDescriptor<UserEntity>())
            .max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }?
            .toStoredUser()
    }

    package func fetchRecord(userId: UUID) throws -> StoredUser? {
        try entity(withID: userId)?.toStoredUser()
    }

    /// Overwrites the stored row, leaving its confirmation stamp alone.
    ///
    /// The write now covers every mapped field — see `UserEntity.overwrite(with:)`
    /// for the two it used to drop and why that stopped being survivable when
    /// the row became the thing a read is answered from.
    ///
    /// `refreshedAt` is untouched because an update says what the row contains
    /// and not where it came from; `save(user:refreshedAt:)` is the write that
    /// gets to claim the API confirmed it.
    package func update(user: User) throws {
        guard let entity = try entity(withID: user.id) else {
            throw PersistenceError.userNotFound
        }
        entity.overwrite(with: user)
        try context.save()
    }

    package func delete(userId: UUID) throws {
        guard let entity = try entity(withID: userId) else {
            throw PersistenceError.userNotFound
        }
        context.delete(entity)
        try context.save()
    }

    /// Looks up one entity by identity.
    ///
    /// This reads as the job of `FetchDescriptor(predicate: #Predicate { $0.id == id })`,
    /// and that is what it used to be. Executing that fetch traps inside SwiftData
    /// (`EXC_BREAKPOINT`) on this model, in the same frame that a sort over an optional
    /// key path does — see `fetchCurrentUser()`. `UserEntity.id` is a `UUID`, and
    /// SwiftData does not reliably translate a `UUID` comparison in a `#Predicate` into
    /// a store query. Since it traps rather than throwing, one call takes the whole
    /// process with it.
    ///
    /// The same reasoning as `fetchCurrentUser()` applies: this store holds the
    /// signed-in user, so "fetch all and match" is over a handful of rows. On a model
    /// with real row counts this would be the wrong shape, and the fix would be to give
    /// the entity a `String` identifier the predicate can compare.
    private func entity(withID id: UUID) throws -> UserEntity? {
        try context.fetch(FetchDescriptor<UserEntity>())
            .first { $0.id == id }
    }

    package func deleteAll() throws {
        let all = try context.fetch(FetchDescriptor<UserEntity>())
        for entity in all { context.delete(entity) }
        try context.save()
    }
}

// MARK: - Mock for previews and tests

@MainActor
package final class MockUserPersistenceService: UserPersistenceService {
    package init() {}

    package var storage: [UUID: User] = [:]

    /// The confirmation stamps, keyed the same way as `storage`.
    ///
    /// Kept beside the rows rather than folded into them so that `storage`
    /// stays a dictionary of the domain type — every existing assertion reads
    /// `storage[id]?.name` — while the double still answers the same questions
    /// about staleness as the real store.
    package var stamps: [UUID: Date] = [:]

    package var shouldThrow = false
    package var stubbedError: PersistenceError = .userNotFound

    private(set) var saveCallCount = 0
    private(set) var fetchCallCount = 0
    private(set) var updateCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var deleteAllCallCount = 0

    package func save(user: User) throws {
        try save(user: user, refreshedAt: nil)
    }

    package func save(user: User, refreshedAt: Date?) throws {
        saveCallCount += 1
        if shouldThrow { throw stubbedError }
        storage[user.id] = user
        // Assigning `nil` removes the key, which is the clearing behaviour the
        // protocol specifies for a save that heard nothing from the API.
        stamps[user.id] = refreshedAt
    }

    package func fetchCurrentUser() throws -> User? {
        try fetchCurrentRecord()?.user
    }

    package func fetchCurrentRecord() throws -> StoredUser? {
        fetchCallCount += 1
        if shouldThrow { throw stubbedError }
        guard let user = storage.values
            .max(by: { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) })
        else {
            return nil
        }
        return StoredUser(user: user, refreshedAt: stamps[user.id])
    }

    package func fetchRecord(userId: UUID) throws -> StoredUser? {
        fetchCallCount += 1
        if shouldThrow { throw stubbedError }
        guard let user = storage[userId] else { return nil }
        return StoredUser(user: user, refreshedAt: stamps[userId])
    }

    package func update(user: User) throws {
        updateCallCount += 1
        if shouldThrow { throw stubbedError }
        guard storage[user.id] != nil else { throw PersistenceError.userNotFound }
        storage[user.id] = user
    }

    package func delete(userId: UUID) throws {
        deleteCallCount += 1
        if shouldThrow { throw stubbedError }
        guard storage[userId] != nil else { throw PersistenceError.userNotFound }
        storage.removeValue(forKey: userId)
        stamps.removeValue(forKey: userId)
    }

    package func deleteAll() throws {
        deleteAllCallCount += 1
        if shouldThrow { throw stubbedError }
        storage.removeAll()
        stamps.removeAll()
    }
}
