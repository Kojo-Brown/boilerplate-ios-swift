import Foundation
import SwiftData
import Testing
import os
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

// MARK: - Doubles local to this suite

/// A repository whose answer and whose failure are both set by the test.
///
/// `MockUserRepository` cannot do this job: it throws `UserRepositoryError` and
/// only that, and half of what these strategies decide is *which* failure means
/// "fall back to the cache". `docs/solid.md` finding 4 is why there are two
/// error vocabularies to script against.
///
/// It is nonisolated, like `LiveUserRepository` and unlike `MockUserRepository`
/// — finding 5's recommendation, applied to a double written after the finding
/// rather than before it. State is in a lock for the same reason.
private final class ScriptedUserRepository: UserRepository {

    private struct State: Sendable {
        var user = User(email: "sync@example.invalid", name: "Sync User")
        var fetchError: (any Error & Sendable)?
        var updateError: (any Error & Sendable)?
        var fetchCount = 0
        var updateCount = 0
        var requestedNames: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var user: User {
        get { state.withLock { $0.user } }
        set { state.withLock { $0.user = newValue } }
    }

    var fetchError: (any Error & Sendable)? {
        get { state.withLock { $0.fetchError } }
        set { state.withLock { $0.fetchError = newValue } }
    }

    var updateError: (any Error & Sendable)? {
        get { state.withLock { $0.updateError } }
        set { state.withLock { $0.updateError = newValue } }
    }

    var fetchCount: Int { state.withLock { $0.fetchCount } }
    var updateCount: Int { state.withLock { $0.updateCount } }
    var requestedNames: [String] { state.withLock { $0.requestedNames } }

    func fetchCurrentUser() async throws -> User {
        let snapshot = state.withLock { current -> State in
            current.fetchCount += 1
            return current
        }
        if let error = snapshot.fetchError { throw error }
        return snapshot.user
    }

    func updateProfile(name: String) async throws -> User {
        let snapshot = state.withLock { current -> State in
            current.updateCount += 1
            current.requestedNames.append(name)
            if current.updateError == nil {
                current.user = current.user.with(name: .set(name))
            }
            return current
        }
        if let error = snapshot.updateError { throw error }
        return snapshot.user
    }

    func deleteAccount() async throws {}
}

/// A monotonic instant the test moves by hand.
///
/// `CacheFirstSyncStrategy` takes its clock as a parameter precisely so a
/// freshness window can be tested without a `Task.sleep` — Phase 7 recorded
/// that `withTimeout` shipped without that seam and that its suite pays for it
/// in real seconds.
private struct FakeMonotonicClock: Sendable {

    private let instant = OSAllocatedUnfairLock<ContinuousClock.Instant>(
        initialState: ContinuousClock.now
    )

    /// The provider handed to `CacheFirstSyncStrategy(now:)`.
    var now: @Sendable () -> ContinuousClock.Instant {
        let instant = self.instant
        return { instant.withLock { $0 } }
    }

    func advance(by duration: Duration) {
        instant.withLock { $0 = $0.advanced(by: duration) }
    }
}

private let offlineFailure = APIError.networkUnavailable(URLError(.notConnectedToInternet))

// MARK: - Classifying a failure

@Suite("SyncFailure — which failures the cache is an answer to")
struct SyncFailureTests {

    @Test("A transport failure from the live vocabulary counts as offline")
    func apiTransportFailureIsOffline() {
        #expect(SyncFailure.isOffline(offlineFailure))
    }

    /// Finding 4 in practice: the double throws a different type for the same
    /// condition, so a policy that knew only `APIError` would behave one way
    /// under test and another in the app.
    @Test("A transport failure from the double's vocabulary counts as offline")
    func repositoryTransportFailureIsOffline() {
        #expect(SyncFailure.isOffline(UserRepositoryError.networkUnavailable))
    }

    /// The narrowness is the point: an expired session must not be answered
    /// with the last profile the device happened to keep.
    @Test("Everything else does not", arguments: [
        APIError.unauthorized,
        APIError.decodingFailed("mock-decoding-failure"),
        APIError.httpError(statusCode: 500, data: Data()),
    ])
    func otherApiFailuresAreNotOffline(error: APIError) {
        #expect(!SyncFailure.isOffline(error))
    }

    @Test("A store failure is not an offline failure")
    func persistenceFailureIsNotOffline() {
        #expect(!SyncFailure.isOffline(PersistenceError.userNotFound))
        #expect(!SyncFailure.isOffline(UserRepositoryError.notFound))
    }
}

// MARK: - Remote only

@Suite("RemoteOnlySyncStrategy")
@MainActor
struct RemoteOnlySyncStrategyTests {

    @Test("It reads the API and keeps no copy")
    func readsTheApiAndKeepsNoCopy() async throws {
        let repository = ScriptedUserRepository()
        let strategy = RemoteOnlySyncStrategy(repository: repository)

        let synced = try await strategy.loadCurrentUser()

        #expect(synced.origin == .remote)
        #expect(synced.user == repository.user)
        #expect(strategy.policy == .remoteOnly)
    }

    /// With no store there is nothing to fall back to, so an offline failure
    /// surfaces rather than being softened.
    @Test("An offline failure propagates")
    func offlineFailurePropagates() async {
        let repository = ScriptedUserRepository()
        repository.fetchError = offlineFailure
        let strategy = RemoteOnlySyncStrategy(repository: repository)

        await #expect(throws: APIError.self) {
            _ = try await strategy.loadCurrentUser()
        }
    }

    @Test("A write goes straight to the API")
    func writeGoesToTheApi() async throws {
        let repository = ScriptedUserRepository()
        let strategy = RemoteOnlySyncStrategy(repository: repository)

        let updated = try await strategy.updateProfile(name: "Renamed")

        #expect(updated.name == "Renamed")
        #expect(repository.requestedNames == ["Renamed"])
    }
}

// MARK: - Remote first

@Suite("RemoteFirstSyncStrategy")
@MainActor
struct RemoteFirstSyncStrategyTests {

    @Test("A successful read is written through to the store")
    func successfulReadIsWrittenThrough() async throws {
        let repository = ScriptedUserRepository()
        let store = MockUserPersistenceService()
        let strategy = RemoteFirstSyncStrategy(repository: repository, store: store)

        let synced = try await strategy.loadCurrentUser()

        #expect(synced.origin == .remote)
        #expect(store.storage[repository.user.id] == repository.user)
    }

    @Test("An offline read is answered by the store")
    func offlineReadIsAnsweredByTheStore() async throws {
        let repository = ScriptedUserRepository()
        let store = MockUserPersistenceService()
        let cached = User(email: "cached@example.invalid", name: "Cached User")
        try store.save(user: cached)
        repository.fetchError = offlineFailure

        let strategy = RemoteFirstSyncStrategy(repository: repository, store: store)
        let synced = try await strategy.loadCurrentUser()

        #expect(synced.origin == .localCache)
        #expect(synced.user == cached)
    }

    @Test("An offline read with an empty store rethrows")
    func offlineReadWithAnEmptyStoreRethrows() async {
        let repository = ScriptedUserRepository()
        repository.fetchError = offlineFailure
        let strategy = RemoteFirstSyncStrategy(
            repository: repository,
            store: MockUserPersistenceService()
        )

        await #expect(throws: APIError.self) {
            _ = try await strategy.loadCurrentUser()
        }
    }

    /// The failure this policy must not soften. A 401 means the session is
    /// gone; answering it from the cache makes a signed-out app look signed in.
    @Test("An expired session is not answered from the cache")
    func expiredSessionIsNotAnsweredFromTheCache() async throws {
        let repository = ScriptedUserRepository()
        let store = MockUserPersistenceService()
        try store.save(user: User(email: "cached@example.invalid", name: "Cached User"))
        repository.fetchError = APIError.unauthorized

        let strategy = RemoteFirstSyncStrategy(repository: repository, store: store)

        await #expect(throws: APIError.self) {
            _ = try await strategy.loadCurrentUser()
        }
    }

    /// `docs/solid.md` finding 3 predicted the caller that would expose it: a
    /// save on every launch leaves two rows in the real store and one entry in
    /// the double, because `SwiftDataUserPersistenceService.save(user:)`
    /// inserts. This item is that caller, so it goes through
    /// `writeThrough(_:)` — and this runs against the SwiftData store rather
    /// than the double, because the double would agree either way.
    @Test("Repeated reads do not accumulate rows in the SwiftData store")
    func repeatedReadsDoNotAccumulateRows() async throws {
        let modelContainer = try PersistenceController.makeInMemoryContainer()
        let context = modelContainer.mainContext
        let store = SwiftDataUserPersistenceService(context: context)
        let repository = ScriptedUserRepository()
        let strategy = RemoteFirstSyncStrategy(repository: repository, store: store)

        _ = try await strategy.loadCurrentUser()
        _ = try await strategy.loadCurrentUser()
        _ = try await strategy.loadCurrentUser()

        let rows = try context.fetch(FetchDescriptor<UserEntity>())
        #expect(rows.count == 1)
        #expect(rows.first?.id == repository.user.id)
    }

    /// A rename has to reach the copy too, or the next offline read serves the
    /// old name back.
    @Test("A write is written through to the store")
    func writeIsWrittenThrough() async throws {
        let repository = ScriptedUserRepository()
        let store = MockUserPersistenceService()
        let strategy = RemoteFirstSyncStrategy(repository: repository, store: store)
        _ = try await strategy.loadCurrentUser()

        let updated = try await strategy.updateProfile(name: "Renamed")

        #expect(store.storage[updated.id]?.name == "Renamed")
        #expect(store.storage.count == 1)
    }

    /// The documented choice: a cache that cannot accept the row is a cache
    /// that is silently useless from here on, so the failure surfaces.
    @Test("A store that refuses the write fails the read")
    func storeFailurePropagates() async {
        let store = MockUserPersistenceService()
        store.shouldThrow = true
        let strategy = RemoteFirstSyncStrategy(
            repository: ScriptedUserRepository(),
            store: store
        )

        await #expect(throws: PersistenceError.self) {
            _ = try await strategy.loadCurrentUser()
        }
    }
}

// MARK: - Cache first

@Suite("CacheFirstSyncStrategy")
@MainActor
struct CacheFirstSyncStrategyTests {

    /// Nothing in memory says when the row was fetched, so a cold start always
    /// asks the API. That is the cost of not persisting the timestamp, stated
    /// as a test rather than only in a comment.
    @Test("The first read of a process goes to the API")
    func firstReadGoesToTheApi() async throws {
        let clock = makeClock()
        let repository = ScriptedUserRepository()
        let store = MockUserPersistenceService()
        try store.save(user: User(email: "cached@example.invalid", name: "Cached User"))
        let strategy = makeStrategy(repository: repository, store: store, clock: clock)

        let synced = try await strategy.loadCurrentUser()

        #expect(synced.origin == .remote)
        #expect(repository.fetchCount == 1)
    }

    @Test("A second read inside the window is answered by the store")
    func secondReadInsideTheWindowIsAnsweredByTheStore() async throws {
        let clock = makeClock()
        let repository = ScriptedUserRepository()
        let strategy = makeStrategy(
            repository: repository,
            store: MockUserPersistenceService(),
            clock: clock
        )

        _ = try await strategy.loadCurrentUser()
        clock.advance(by: .seconds(59))
        let synced = try await strategy.loadCurrentUser()

        #expect(synced.origin == .localCache)
        #expect(repository.fetchCount == 1)
    }

    @Test("Once the window expires the API is asked again")
    func expiredWindowGoesBackToTheApi() async throws {
        let clock = makeClock()
        let repository = ScriptedUserRepository()
        let strategy = makeStrategy(
            repository: repository,
            store: MockUserPersistenceService(),
            clock: clock
        )

        _ = try await strategy.loadCurrentUser()
        clock.advance(by: .seconds(61))
        let synced = try await strategy.loadCurrentUser()

        #expect(synced.origin == .remote)
        #expect(repository.fetchCount == 2)
    }

    @Test("A stale copy is served when the refresh cannot reach the network")
    func staleCopyIsServedWhenOffline() async throws {
        let clock = makeClock()
        let repository = ScriptedUserRepository()
        let strategy = makeStrategy(
            repository: repository,
            store: MockUserPersistenceService(),
            clock: clock
        )

        let first = try await strategy.loadCurrentUser()
        clock.advance(by: .seconds(120))
        repository.fetchError = offlineFailure
        let second = try await strategy.loadCurrentUser()

        #expect(second.origin == .localCache)
        #expect(second.user == first.user)
    }

    /// A write is fresher than anything a read could return, so it restarts the
    /// window instead of leaving the next read to fetch what this call sent.
    @Test("A write restarts the freshness window")
    func writeRestartsTheWindow() async throws {
        let clock = makeClock()
        let repository = ScriptedUserRepository()
        let store = MockUserPersistenceService()
        let strategy = makeStrategy(repository: repository, store: store, clock: clock)

        _ = try await strategy.loadCurrentUser()
        clock.advance(by: .seconds(120))
        _ = try await strategy.updateProfile(name: "Renamed")
        let synced = try await strategy.loadCurrentUser()

        #expect(synced.origin == .localCache)
        #expect(synced.user.name == "Renamed")
        #expect(repository.fetchCount == 1)
    }

    // MARK: - Helpers

    private func makeClock() -> FakeMonotonicClock {
        FakeMonotonicClock()
    }

    private func makeStrategy(
        repository: any UserRepository,
        store: any UserPersistenceService,
        clock: FakeMonotonicClock
    ) -> CacheFirstSyncStrategy {
        CacheFirstSyncStrategy(
            repository: repository,
            store: store,
            maxAge: .seconds(60),
            now: clock.now
        )
    }
}

// MARK: - The factory

@Suite("LiveSyncStrategyFactory")
@MainActor
struct SyncStrategyFactoryTests {

    @Test("Every policy resolves to a strategy that reports it", arguments: SyncPolicy.allCases)
    func everyPolicyResolves(policy: SyncPolicy) {
        #expect(makeFactory().makeStrategy(for: policy).policy == policy)
    }

    /// `cacheFirst` carries a freshness window as mutable state, so a shared
    /// instance would let one screen's read reset another's.
    @Test("Each call builds a new strategy")
    func eachCallBuildsANewStrategy() throws {
        let factory = makeFactory()
        let first = try #require(
            factory.makeStrategy(for: .cacheFirst) as? CacheFirstSyncStrategy
        )
        let second = try #require(
            factory.makeStrategy(for: .cacheFirst) as? CacheFirstSyncStrategy
        )
        #expect(first !== second)
    }

    /// The strategies come back wired to the collaborators the factory holds,
    /// which is the whole reason a caller can ask for a policy without having
    /// the graph.
    @Test("The strategies it builds are wired to its collaborators")
    func strategiesAreWiredToItsCollaborators() async throws {
        let repository = ScriptedUserRepository()
        let store = MockUserPersistenceService()
        let factory = LiveSyncStrategyFactory(repository: repository, store: store)

        _ = try await factory.makeStrategy(for: .remoteFirst).loadCurrentUser()

        #expect(repository.fetchCount == 1)
        #expect(store.storage[repository.user.id] == repository.user)
    }

    @Test("The double records what it was asked for")
    func theDoubleRecordsItsRequests() {
        let factory = MockSyncStrategyFactory()
        _ = factory.makeStrategy(for: .remoteOnly)
        _ = factory.makeStrategy(for: .cacheFirst)
        #expect(factory.requestedPolicies == [.remoteOnly, .cacheFirst])
    }

    private func makeFactory() -> LiveSyncStrategyFactory {
        LiveSyncStrategyFactory(
            repository: ScriptedUserRepository(),
            store: MockUserPersistenceService()
        )
    }
}
