import Foundation
import SwiftData
import Testing
import os
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

// MARK: - Doubles local to this file

/// A wall clock the test moves by hand.
///
/// `OfflineFirstSyncStrategy` measures its window against `Date`, not
/// `ContinuousClock`, because the stamp it compares to outlives the process —
/// so `FakeMonotonicClock` cannot drive it and this is its wall-clock twin. The
/// fixed origin matters: a stamp written by one test and read by another must
/// be comparable, and `Date()` at two points in a suite is not a fixture.
private struct FakeWallClock: Sendable {

    private let instant = OSAllocatedUnfairLock<Date>(
        initialState: Date(timeIntervalSince1970: 1_700_000_000)
    )

    /// The provider handed to `OfflineFirstSyncStrategy(now:)`.
    var now: @Sendable () -> Date {
        let locked = instant
        return { locked.withLock { $0 } }
    }

    var current: Date { instant.withLock { $0 } }

    func advance(by interval: TimeInterval) {
        instant.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

/// A store that is allowed to lose things on the way in.
///
/// It exists for one claim: this policy returns *the row*, not the response
/// that produced the row. A store that silently drops a write, or truncates a
/// field while accepting it, is indistinguishable from a healthy one to a
/// strategy that hands the API's answer straight back — and it is exactly what
/// this package shipped until this item, since `update(user:)` wrote three of
/// the five mapped columns.
///
/// `MockUserPersistenceService` cannot do this job: it is faithful by
/// construction, which is the right default for every other suite.
@MainActor
private final class LossyUserStore: UserPersistenceService {

    /// What the store does to a row on its way in. `nil` drops the write.
    var onWrite: (User) -> User? = { $0 }

    private var rows: [UUID: StoredUser] = [:]

    init() {}

    func save(user: User) throws {
        try save(user: user, refreshedAt: nil)
    }

    func save(user: User, refreshedAt: Date?) throws {
        guard let kept = onWrite(user) else { return }
        rows[kept.id] = StoredUser(user: kept, refreshedAt: refreshedAt)
    }

    func fetchCurrentUser() throws -> User? {
        try fetchCurrentRecord()?.user
    }

    func fetchCurrentRecord() throws -> StoredUser? {
        rows.values
            .max { ($0.user.createdAt ?? .distantPast) < ($1.user.createdAt ?? .distantPast) }
    }

    func fetchRecord(userId: UUID) throws -> StoredUser? {
        rows[userId]
    }

    func update(user: User) throws {
        guard let existing = rows[user.id] else { throw PersistenceError.userNotFound }
        rows[user.id] = StoredUser(user: user, refreshedAt: existing.refreshedAt)
    }

    func delete(userId: UUID) throws {
        guard rows.removeValue(forKey: userId) != nil else {
            throw PersistenceError.userNotFound
        }
    }

    func deleteAll() throws {
        rows.removeAll()
    }
}

// MARK: - The stamp

@Suite("StoredUser — what the persisted stamp means")
struct StoredUserFreshnessTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A row confirmed inside the window is fresh")
    func recentRowIsFresh() {
        let stored = StoredUser(user: Self.user, refreshedAt: epoch)
        #expect(stored.isFresh(at: epoch.addingTimeInterval(59), maxAge: .seconds(60)))
    }

    @Test("A row confirmed outside the window is not")
    func agedRowIsStale() {
        let stored = StoredUser(user: Self.user, refreshedAt: epoch)
        #expect(!stored.isFresh(at: epoch.addingTimeInterval(61), maxAge: .seconds(60)))
    }

    /// "Never confirmed" is not "just confirmed". A row seeded or restored from
    /// somewhere other than an API response has no claim on the window.
    @Test("A row that was never confirmed is never fresh")
    func unstampedRowIsStale() {
        let stored = StoredUser(user: Self.user, refreshedAt: nil)
        #expect(!stored.isFresh(at: epoch, maxAge: .seconds(60)))
        #expect(stored.age(at: epoch) == nil)
    }

    /// The price of a wall-clock stamp, paid deliberately. A device whose clock
    /// moved backwards holds a row stamped in its own future; trusting the
    /// magnitude alone would keep that row fresh for as long as the skew lasts.
    @Test("A row stamped in the future is stale, not indefinitely fresh")
    func futureStampIsStale() {
        let stored = StoredUser(user: Self.user, refreshedAt: epoch.addingTimeInterval(3_600))
        #expect(!stored.isFresh(at: epoch, maxAge: .seconds(60)))
        #expect((stored.age(at: epoch) ?? 0) < 0)
    }

    @Test("A Duration converts to the seconds a Date comparison needs")
    func durationConvertsToSeconds() {
        #expect(Duration.seconds(90).seconds == 90)
        #expect(Duration.milliseconds(1_500).seconds == 1.5)
    }

    private static let user = User(email: "stamp@example.invalid", name: "Stamp")
}

// MARK: - The policy, against a double

@Suite("OfflineFirstSyncStrategy")
@MainActor
struct OfflineFirstSyncStrategyTests {

    /// The property `cacheFirst` cannot have, and the reason this item exists.
    ///
    /// The strategy is built fresh — it has never seen this store, exactly as a
    /// relaunched process has not — and it answers without a request, because
    /// the freshness is on the row rather than in the memory of the process
    /// that fetched it. `CacheFirstSyncStrategyTests.firstReadGoesToTheApi`
    /// pins the opposite for the in-memory window.
    @Test("A cold launch inside the window makes no request")
    func coldLaunchInsideTheWindowMakesNoRequest() async throws {
        let clock = FakeWallClock()
        let repository = ScriptedUserRepository()
        let store = MockUserPersistenceService()
        let stored = User(email: "stored@example.invalid", name: "Stored User")
        try store.save(user: stored, refreshedAt: clock.current)
        clock.advance(by: 30)

        let synced = try await makeStrategy(repository: repository, store: store, clock: clock)
            .loadCurrentUser()

        #expect(synced.origin == .localCache)
        #expect(synced.user == stored)
        #expect(repository.fetchCount == 0)
    }

    @Test("An empty store is refreshed and the row is stamped")
    func emptyStoreIsFilledFromTheApi() async throws {
        let clock = FakeWallClock()
        let repository = ScriptedUserRepository()
        let store = MockUserPersistenceService()

        let synced = try await makeStrategy(repository: repository, store: store, clock: clock)
            .loadCurrentUser()

        #expect(synced.origin == .remote)
        #expect(synced.user == repository.user)
        #expect(repository.fetchCount == 1)
        #expect(store.stamps[repository.user.id] == clock.current)
    }

    /// A row nobody heard from the server is a row with no claim on the window,
    /// however recently it was written.
    @Test("A row with no stamp is refreshed")
    func unstampedRowIsRefreshed() async throws {
        let clock = FakeWallClock()
        let repository = ScriptedUserRepository()
        let store = MockUserPersistenceService()
        try store.save(user: User(email: "seeded@example.invalid", name: "Seeded"))

        let synced = try await makeStrategy(repository: repository, store: store, clock: clock)
            .loadCurrentUser()

        #expect(synced.origin == .remote)
        #expect(repository.fetchCount == 1)
    }

    @Test("Once the row ages past the window the API is asked and the stamp moves")
    func agedRowIsRefreshedAndRestamped() async throws {
        let clock = FakeWallClock()
        let repository = ScriptedUserRepository()
        let store = MockUserPersistenceService()
        let strategy = makeStrategy(repository: repository, store: store, clock: clock)

        _ = try await strategy.loadCurrentUser()
        clock.advance(by: 61)
        let synced = try await strategy.loadCurrentUser()

        #expect(synced.origin == .remote)
        #expect(repository.fetchCount == 2)
        #expect(store.stamps[repository.user.id] == clock.current)
    }

    /// A failed refresh is not a failed read. This is the whole offline story:
    /// the row is the answer, and the network was only ever going to improve it.
    @Test("An offline refresh serves the stored row")
    func offlineRefreshServesTheStoredRow() async throws {
        let clock = FakeWallClock()
        let repository = ScriptedUserRepository()
        let store = MockUserPersistenceService()
        let strategy = makeStrategy(repository: repository, store: store, clock: clock)

        let first = try await strategy.loadCurrentUser()
        clock.advance(by: 3_600)
        repository.fetchError = offlineFailure
        let second = try await strategy.loadCurrentUser()

        #expect(second.origin == .localCache)
        #expect(second.user == first.user)
    }

    /// Being the source of truth is a claim about where a value comes from, not
    /// a licence to serve it after the server has said the caller may not have
    /// it. `SyncFailure.isOffline(_:)` is not widened for this policy.
    @Test("An expired session is not answered from the store")
    func expiredSessionIsNotAnsweredFromTheStore() async throws {
        let clock = FakeWallClock()
        let repository = ScriptedUserRepository()
        let store = MockUserPersistenceService()
        try store.save(user: User(email: "stored@example.invalid", name: "Stored"))
        repository.fetchError = APIError.unauthorized

        let strategy = makeStrategy(repository: repository, store: store, clock: clock)

        await #expect(throws: APIError.self) {
            _ = try await strategy.loadCurrentUser()
        }
    }

    /// The one state an offline-first app has nothing to show for: it has never
    /// successfully synced.
    @Test("An offline read with an empty store fails")
    func offlineReadWithAnEmptyStoreFails() async {
        let clock = FakeWallClock()
        let repository = ScriptedUserRepository()
        repository.fetchError = offlineFailure
        let strategy = makeStrategy(
            repository: repository,
            store: MockUserPersistenceService(),
            clock: clock
        )

        await #expect(throws: APIError.self) {
            _ = try await strategy.loadCurrentUser()
        }
    }

    /// A store that cannot be read is a failed read, not a quiet downgrade to
    /// `remoteOnly` — the repository is never asked.
    @Test("A store failure fails the read instead of falling through to the API")
    func storeFailureFailsTheRead() async {
        let clock = FakeWallClock()
        let repository = ScriptedUserRepository()
        let store = MockUserPersistenceService()
        store.shouldThrow = true
        let strategy = makeStrategy(repository: repository, store: store, clock: clock)

        await #expect(throws: PersistenceError.self) {
            _ = try await strategy.loadCurrentUser()
        }
        #expect(repository.fetchCount == 0)
    }

    /// The read-back, stated as behaviour. The store here keeps the write but
    /// changes it, and what comes back is what the store kept — which is what
    /// the next launch will read, and therefore the only honest answer.
    @Test("The value returned after a refresh is the row, not the response")
    func returnedValueIsTheRowRatherThanTheResponse() async throws {
        let clock = FakeWallClock()
        let repository = ScriptedUserRepository()
        let store = LossyUserStore()
        store.onWrite = { $0.with(name: .set("Truncated")) }
        let strategy = makeStrategy(repository: repository, store: store, clock: clock)

        let synced = try await strategy.loadCurrentUser()

        #expect(synced.origin == .remote)
        #expect(synced.user.name == "Truncated")
        #expect(repository.user.name != "Truncated")
    }

    /// The other half: a store that accepts the write and keeps nothing has no
    /// answer to give, so the read fails rather than returning a value no
    /// subsequent read could reproduce.
    @Test("A store that keeps nothing fails the read")
    func storeThatKeepsNothingFailsTheRead() async {
        let clock = FakeWallClock()
        let store = LossyUserStore()
        store.onWrite = { _ in nil }
        let strategy = makeStrategy(
            repository: ScriptedUserRepository(),
            store: store,
            clock: clock
        )

        await #expect(throws: PersistenceError.self) {
            _ = try await strategy.loadCurrentUser()
        }
    }

    /// A write is a fresher confirmation than any read could produce, so it
    /// restamps the row and the next read inside the window is free.
    @Test("A write restamps the row")
    func writeRestampsTheRow() async throws {
        let clock = FakeWallClock()
        let repository = ScriptedUserRepository()
        let store = MockUserPersistenceService()
        let strategy = makeStrategy(repository: repository, store: store, clock: clock)

        _ = try await strategy.loadCurrentUser()
        clock.advance(by: 3_600)
        let updated = try await strategy.updateProfile(name: "Renamed")
        let synced = try await strategy.loadCurrentUser()

        #expect(updated.name == "Renamed")
        #expect(synced.origin == .localCache)
        #expect(synced.user.name == "Renamed")
        #expect(repository.fetchCount == 1)
        #expect(store.stamps[updated.id] == clock.current)
    }

    /// There is no local-only write here: an edit that never leaves the device
    /// needs an outbox and a merge rule, which are later items in this phase.
    @Test("An offline write fails rather than queueing")
    func offlineWriteFails() async {
        let clock = FakeWallClock()
        let repository = ScriptedUserRepository()
        repository.updateError = offlineFailure
        let strategy = makeStrategy(
            repository: repository,
            store: MockUserPersistenceService(),
            clock: clock
        )

        await #expect(throws: APIError.self) {
            _ = try await strategy.updateProfile(name: "Renamed")
        }
    }

    @Test("It reports its policy")
    func reportsItsPolicy() {
        let strategy = makeStrategy(
            repository: ScriptedUserRepository(),
            store: MockUserPersistenceService(),
            clock: FakeWallClock()
        )
        #expect(strategy.policy == .offlineFirst)
    }

    // MARK: - Helpers

    private func makeStrategy(
        repository: any UserRepository,
        store: any UserPersistenceService,
        clock: FakeWallClock
    ) -> OfflineFirstSyncStrategy {
        OfflineFirstSyncStrategy(
            repository: repository,
            store: store,
            maxAge: .seconds(60),
            now: clock.now
        )
    }
}

// MARK: - The policy, against the real store

/// The claims that only SwiftData can answer for.
///
/// `.serialized` and the stored container follow `UserPersistenceTests`: a
/// `ModelContext` does not keep its `ModelContainer` alive, and a container
/// built inside a helper is deallocated before the test body runs, which
/// SwiftData reports by trapping and taking the whole process with it.
@Suite("OfflineFirstSyncStrategy — against SwiftData", .serialized)
@MainActor
struct OfflineFirstSyncStrategyStoreTests {

    private let container: ModelContainer
    private let store: SwiftDataUserPersistenceService

    init() throws {
        container = try PersistenceController.makeInMemoryContainer()
        store = SwiftDataUserPersistenceService(context: container.mainContext)
    }

    /// The relaunch, as far as a test process can stage one: the first strategy
    /// is discarded and a second is built over the same store, holding none of
    /// the first one's memory. It asks nothing, because the stamp is a column.
    @Test("A second strategy over the same store inherits the window")
    func secondStrategyInheritsTheWindow() async throws {
        let clock = FakeWallClock()
        let repository = ScriptedUserRepository()

        _ = try await makeStrategy(repository: repository, clock: clock).loadCurrentUser()
        clock.advance(by: 30)
        let synced = try await makeStrategy(repository: repository, clock: clock).loadCurrentUser()

        #expect(synced.origin == .localCache)
        #expect(synced.user == repository.user)
        #expect(repository.fetchCount == 1)
    }

    /// The same pin `RemoteFirstSyncStrategyTests` carries, against the policy
    /// that writes on every refresh. It runs on the real store because the
    /// double would have agreed either way — which is the whole shape of
    /// `docs/solid.md` finding 3.
    @Test("Repeated refreshes leave one row")
    func repeatedRefreshesLeaveOneRow() async throws {
        let clock = FakeWallClock()
        let repository = ScriptedUserRepository()
        let strategy = makeStrategy(repository: repository, clock: clock)

        _ = try await strategy.loadCurrentUser()
        clock.advance(by: 61)
        _ = try await strategy.loadCurrentUser()
        clock.advance(by: 61)
        _ = try await strategy.loadCurrentUser()

        let rows = try container.mainContext.fetch(FetchDescriptor<UserEntity>())
        #expect(rows.count == 1)
        #expect(rows.first?.refreshedAt == clock.current)
        #expect(repository.fetchCount == 3)
    }

    /// The field the store used to drop. A profile whose email changed on
    /// another device was written to disk, silently truncated back to the old
    /// value, and then — under this policy — served as the truth.
    @Test("A refresh persists every field, not the three an edit was assumed to touch")
    func refreshPersistsEveryField() async throws {
        let clock = FakeWallClock()
        let repository = ScriptedUserRepository()
        let strategy = makeStrategy(repository: repository, clock: clock)

        _ = try await strategy.loadCurrentUser()
        repository.user = User(
            id: repository.user.id,
            email: "moved@example.invalid",
            name: repository.user.name,
            avatarURL: URL(string: "https://example.invalid/avatar.png"),
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        clock.advance(by: 61)
        let synced = try await strategy.loadCurrentUser()

        #expect(synced.user == repository.user)
        let stored = try #require(store.fetchRecord(userId: repository.user.id))
        #expect(stored.user == repository.user)
    }

    private func makeStrategy(
        repository: any UserRepository,
        clock: FakeWallClock
    ) -> OfflineFirstSyncStrategy {
        OfflineFirstSyncStrategy(
            repository: repository,
            store: store,
            maxAge: .seconds(60),
            now: clock.now
        )
    }
}
