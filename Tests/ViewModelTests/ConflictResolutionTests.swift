import Foundation
import SwiftData
import Testing
import os
@testable import Core
@testable import Networking

// MARK: - Fixtures local to this file

/// A wall clock the test moves by hand.
///
/// A second one, rather than `OfflineFirstSyncStrategyTests`' `FakeWallClock`,
/// because that one is `private` to its file. Sharing it would mean promoting
/// it to module scope beside `ScriptedUserRepository`, and a clock is three
/// lines where a scripted repository is eighty — the duplication is cheaper
/// than the coupling.
private struct MergeWallClock: Sendable {

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

private let mergeUserID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

private func mergeUser(
    name: String = "Stored",
    version: Int? = nil,
    updatedAt: Date? = nil
) -> User {
    User(
        id: mergeUserID,
        email: "merge@example.invalid",
        name: name,
        updatedAt: updatedAt,
        version: version
    )
}

// MARK: - The rule

@Suite("LastWriterWinsMergePolicy — which copy of a user wins")
struct LastWriterWinsMergePolicyTests {

    private let policy = LastWriterWinsMergePolicy()
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Nothing stored is nothing to conflict with")
    func noStoredCopyAcceptsTheResponse() {
        let decision = policy.decide(local: nil, remote: mergeUser(version: 1))
        #expect(decision == .noLocalCopy)
        #expect(decision.acceptsRemote)
    }

    /// The store is not cleared on sign-out, so the row it calls "current" can
    /// belong to the previous account. Two different people are not two copies
    /// of one profile, and ordering them by revision would be meaningless.
    @Test("A stored row for a different user is not a conflict")
    func aDifferentUserIsNotAConflict() {
        let stranger = User(email: "other@example.invalid", name: "Other", version: 99)
        let decision = policy.decide(
            local: StoredUser(user: stranger, refreshedAt: epoch),
            remote: mergeUser(version: 1)
        )
        #expect(decision == .differentIdentity)
        #expect(decision.acceptsRemote)
    }

    @Test("A higher revision wins")
    func aHigherRevisionWins() {
        let decision = policy.decide(
            local: StoredUser(user: mergeUser(version: 4), refreshedAt: epoch),
            remote: mergeUser(name: "Fetched", version: 5)
        )
        #expect(decision == .remoteWinsOnVersion)
        #expect(decision.acceptsRemote)
    }

    /// The case the item exists for: a response that is a copy of an older
    /// write. Accepting it rolls the profile back and stamps the rollback as
    /// confirmed.
    @Test("A lower revision is rejected")
    func aLowerRevisionIsRejected() {
        let decision = policy.decide(
            local: StoredUser(user: mergeUser(version: 7), refreshedAt: epoch),
            remote: mergeUser(name: "Fetched", version: 5)
        )
        #expect(decision == .localWinsOnVersion)
        #expect(!decision.acceptsRemote)
    }

    /// Equal revisions describe the same write, so there is no content to lose
    /// — and accepting is what lets the caller restamp the row.
    @Test("An equal revision is accepted")
    func anEqualRevisionIsAccepted() {
        let decision = policy.decide(
            local: StoredUser(user: mergeUser(version: 5), refreshedAt: epoch),
            remote: mergeUser(version: 5)
        )
        #expect(decision == .sameVersion)
        #expect(decision.acceptsRemote)
    }

    @Test("With no revision to compare, the later timestamp wins")
    func theLaterTimestampWinsWithoutARevision() {
        let decision = policy.decide(
            local: StoredUser(user: mergeUser(updatedAt: epoch), refreshedAt: epoch),
            remote: mergeUser(name: "Fetched", updatedAt: epoch.addingTimeInterval(60))
        )
        #expect(decision == .remoteWinsOnTimestamp)
        #expect(decision.acceptsRemote)
    }

    @Test("With no revision to compare, an earlier timestamp is rejected")
    func anEarlierTimestampIsRejectedWithoutARevision() {
        let decision = policy.decide(
            local: StoredUser(user: mergeUser(updatedAt: epoch), refreshedAt: epoch),
            remote: mergeUser(name: "Fetched", updatedAt: epoch.addingTimeInterval(-60))
        )
        #expect(decision == .localWinsOnTimestamp)
        #expect(!decision.acceptsRemote)
    }

    /// A re-fetch of an unchanged profile, which is the ordinary case for every
    /// row written before the revision column existed.
    @Test("Equal timestamps are accepted")
    func equalTimestampsAreAccepted() {
        let decision = policy.decide(
            local: StoredUser(user: mergeUser(updatedAt: epoch), refreshedAt: epoch),
            remote: mergeUser(updatedAt: epoch)
        )
        #expect(decision == .sameTimestamp)
        #expect(decision.acceptsRemote)
    }

    /// The floor, and the behaviour this package had before the policy existed.
    /// Refusing to write here would leave an unversioned, untimestamped profile
    /// frozen on disk forever, which is a worse and quieter failure than the
    /// clobber it avoids.
    @Test("Two copies that cannot be ordered accept the response")
    func twoUnorderableCopiesAcceptTheResponse() {
        let decision = policy.decide(
            local: StoredUser(user: mergeUser(), refreshedAt: epoch),
            remote: mergeUser(name: "Fetched")
        )
        #expect(decision == .unordered)
        #expect(decision.acceptsRemote)
    }

    /// The trap the optionality is there to avoid. If an absent revision read
    /// as zero, then the first response from a deployment that stopped
    /// reporting the field would lose every comparison against a versioned row,
    /// and the profile would never refresh again.
    @Test("An absent revision is not revision zero")
    func absentRevisionIsNotVersionZero() {
        let decision = policy.decide(
            local: StoredUser(user: mergeUser(version: 4, updatedAt: epoch), refreshedAt: epoch),
            remote: mergeUser(name: "Fetched", updatedAt: epoch.addingTimeInterval(60))
        )
        #expect(decision == .remoteWinsOnTimestamp)
        #expect(decision.acceptsRemote)
    }

    /// Every decision has to answer "does the caller write this", and exactly
    /// two of them answer no. Written as a set over `allCases` so that adding a
    /// decision without classifying it fails here rather than being silently
    /// accepted by a `default`.
    @Test("Exactly two decisions reject the response")
    func exactlyTwoDecisionsReject() {
        let rejecting = Set(MergeDecision.allCases.filter { !$0.acceptsRemote })
        #expect(rejecting == [.localWinsOnVersion, .localWinsOnTimestamp])
    }

    @Test("A revision decodes from the API's payload")
    func revisionDecodesFromJSON() throws {
        let json = Data("""
        {
            "id": "00000000-0000-0000-0000-0000000000AA",
            "email": "merge@example.invalid",
            "name": "Merge",
            "version": 7
        }
        """.utf8)

        let user = try JSONDecoder().decode(User.self, from: json)

        #expect(user.version == 7)
    }

    @Test("A response with no revision decodes to nil rather than zero")
    func absentRevisionDecodesToNil() throws {
        let json = Data("""
        {
            "id": "00000000-0000-0000-0000-0000000000AA",
            "email": "merge@example.invalid",
            "name": "Merge"
        }
        """.utf8)

        let user = try JSONDecoder().decode(User.self, from: json)

        #expect(user.version == nil)
    }
}

// MARK: - The rule applied, against a double

@Suite("OfflineFirstSyncStrategy — merging a response into the row")
@MainActor
struct OfflineFirstMergeTests {

    /// The clobber, prevented. The row is left exactly as it was and the caller
    /// is told the value came from the store, because it did.
    @Test("A response older than the row does not overwrite it")
    func staleResponseDoesNotOverwriteTheRow() async throws {
        let clock = MergeWallClock()
        let store = MockUserPersistenceService()
        try store.save(user: mergeUser(name: "Newer", version: 7))
        let repository = ScriptedUserRepository()
        repository.user = mergeUser(name: "Older", version: 5)

        let synced = try await makeStrategy(repository: repository, store: store, clock: clock)
            .loadCurrentUser()

        #expect(synced.origin == .localCache)
        #expect(synced.user.name == "Newer")
        #expect(synced.user.version == 7)
        #expect(repository.fetchCount == 1)
        #expect(store.storage[mergeUserID]?.name == "Newer")
    }

    /// A rejected response is still an exchange with the server. Leaving the
    /// row unstamped would send every subsequent read back to a server that is
    /// behind, for as long as it stays behind.
    @Test("A rejected response still restamps the row")
    func aRejectedResponseStillRestampsTheRow() async throws {
        let clock = MergeWallClock()
        let store = MockUserPersistenceService()
        try store.save(user: mergeUser(name: "Newer", version: 7))
        let repository = ScriptedUserRepository()
        repository.user = mergeUser(name: "Older", version: 5)
        let strategy = makeStrategy(repository: repository, store: store, clock: clock)

        _ = try await strategy.loadCurrentUser()
        #expect(store.stamps[mergeUserID] == clock.current)

        clock.advance(by: 30)
        let second = try await strategy.loadCurrentUser()

        #expect(second.origin == .localCache)
        #expect(repository.fetchCount == 1)
    }

    @Test("A response newer than the row wins and its revision lands on the row")
    func aNewerRevisionWinsAndLandsOnTheRow() async throws {
        let clock = MergeWallClock()
        let store = MockUserPersistenceService()
        try store.save(user: mergeUser(name: "Older", version: 3))
        let repository = ScriptedUserRepository()
        repository.user = mergeUser(name: "Newer", version: 4)

        let synced = try await makeStrategy(repository: repository, store: store, clock: clock)
            .loadCurrentUser()

        #expect(synced.origin == .remote)
        #expect(synced.user.name == "Newer")
        #expect(store.storage[mergeUserID]?.version == 4)
    }

    /// The seam, pinned. The stub says the row wins over two values whose
    /// revisions say the opposite, so a strategy that reimplemented the
    /// comparison inline would overwrite and fail here.
    @Test("The strategy asks the policy rather than comparing revisions itself")
    func theStrategyAsksThePolicy() async throws {
        let clock = MergeWallClock()
        let store = MockUserPersistenceService()
        try store.save(user: mergeUser(name: "Kept", version: 1))
        let repository = ScriptedUserRepository()
        repository.user = mergeUser(name: "Ignored", version: 9)

        let synced = try await makeStrategy(
            repository: repository,
            store: store,
            clock: clock,
            policy: StubbedMergePolicy(.localWinsOnVersion)
        ).loadCurrentUser()

        #expect(synced.origin == .localCache)
        #expect(synced.user.name == "Kept")
        #expect(store.storage[mergeUserID]?.version == 1)
    }

    /// The asymmetry between a read and a write. A read that rejects a response
    /// has the row to hand back; a write does not, because the caller asked for
    /// a change and the server described a profile older than the one on disk.
    @Test("A write whose response is older than the row fails")
    func aWriteWhoseResponseIsOlderFails() async throws {
        let clock = MergeWallClock()
        let store = MockUserPersistenceService()
        try store.save(user: mergeUser(name: "Kept", version: 9))
        let repository = ScriptedUserRepository()
        repository.user = mergeUser(name: "Stale", version: 4)
        let strategy = makeStrategy(repository: repository, store: store, clock: clock)

        await #expect(throws: MergeConflictError.self) {
            _ = try await strategy.updateProfile(name: "Renamed")
        }
        #expect(store.storage[mergeUserID]?.name == "Kept")
    }

    @Test("The conflict error carries both revisions")
    func theConflictErrorCarriesBothRevisions() async throws {
        let clock = MergeWallClock()
        let store = MockUserPersistenceService()
        try store.save(user: mergeUser(name: "Kept", version: 9))
        let repository = ScriptedUserRepository()
        repository.user = mergeUser(name: "Stale", version: 4)
        let strategy = makeStrategy(repository: repository, store: store, clock: clock)

        let expected = MergeConflictError(
            decision: .localWinsOnVersion,
            storedVersion: 9,
            fetchedVersion: 4
        )
        await #expect(throws: expected) {
            _ = try await strategy.updateProfile(name: "Renamed")
        }
    }

    @Test("A write whose response is newer is persisted")
    func aWriteWhoseResponseIsNewerPersists() async throws {
        let clock = MergeWallClock()
        let store = MockUserPersistenceService()
        try store.save(user: mergeUser(name: "Older", version: 4))
        let repository = ScriptedUserRepository()
        repository.user = mergeUser(name: "Older", version: 5)
        let strategy = makeStrategy(repository: repository, store: store, clock: clock)

        let updated = try await strategy.updateProfile(name: "Renamed")

        #expect(updated.name == "Renamed")
        #expect(updated.version == 5)
        #expect(store.stamps[mergeUserID] == clock.current)
    }

    // MARK: - Helpers

    private func makeStrategy(
        repository: any UserRepository,
        store: any UserPersistenceService,
        clock: MergeWallClock,
        policy: any UserMergePolicy = LastWriterWinsMergePolicy()
    ) -> OfflineFirstSyncStrategy {
        OfflineFirstSyncStrategy(
            repository: repository,
            store: store,
            maxAge: .seconds(60),
            mergePolicy: policy,
            now: clock.now
        )
    }
}

// MARK: - The column, against the real store

/// `.serialized` and the stored container follow `UserPersistenceTests`: a
/// `ModelContext` does not keep its `ModelContainer` alive, and a container
/// built inside a helper is deallocated before the test body runs, which
/// SwiftData reports by trapping and taking the whole process with it.
@Suite("The revision column — against SwiftData", .serialized)
@MainActor
struct UserEntityVersionTests {

    private let container: ModelContainer
    private let store: SwiftDataUserPersistenceService

    init() throws {
        container = try PersistenceController.makeInMemoryContainer()
        store = SwiftDataUserPersistenceService(context: container.mainContext)
    }

    @Test("A revision survives a write and a read")
    func revisionRoundTripsThroughTheStore() throws {
        try store.save(user: mergeUser(version: 3))

        // Bound before `#require`: the macro evaluates its argument in a
        // context that does not propagate the fetch's `throws`.
        let fetched = try store.fetchRecord(userId: mergeUserID)
        let stored = try #require(fetched)

        #expect(stored.user.version == 3)
    }

    /// The upsert overwrites the revision along with the content. A row that
    /// took new fields while keeping its old revision would claim to be a
    /// revision it is not, and would lose the next merge it should have won.
    @Test("An upsert moves the revision with the content")
    func upsertMovesTheRevision() throws {
        try store.save(user: mergeUser(name: "First", version: 3))
        try store.save(user: mergeUser(name: "Second", version: 4))

        let fetched = try store.fetchRecord(userId: mergeUserID)
        let stored = try #require(fetched)
        let rows = try container.mainContext.fetch(FetchDescriptor<UserEntity>())

        #expect(rows.count == 1)
        #expect(stored.user.name == "Second")
        #expect(stored.user.version == 4)
    }

    /// What a row written before this item looks like. The column is optional
    /// precisely so SwiftData's lightweight migration can fill it with `nil`,
    /// and `nil` has to mean "unknown" all the way through the policy.
    @Test("A row written without a revision reads back as nil")
    func rowWithoutARevisionReadsBackAsNil() throws {
        try store.save(user: mergeUser())

        let fetched = try store.fetchRecord(userId: mergeUserID)
        let stored = try #require(fetched)

        #expect(stored.user.version == nil)
    }
}
