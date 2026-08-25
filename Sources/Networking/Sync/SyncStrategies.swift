import Core
import Foundation
import os

// MARK: - Remote only

/// The API answers every read and nothing is cached.
///
/// This is the policy for a build with no offline story, and it is also the one
/// an explicit "reload from the server" gesture wants — which is why the
/// factory stays reachable from the composition root instead of being consumed
/// by it. It touches no store at all: not "a store it happens not to write to",
/// but a strategy that has no store to write to, so a caller reading this can
/// see there is no cache path to reason about.
package struct RemoteOnlySyncStrategy: SyncStrategy {
    package var policy: SyncPolicy { .remoteOnly }

    private let repository: any UserRepository

    package init(repository: any UserRepository) {
        self.repository = repository
    }

    package func loadCurrentUser() async throws -> SyncedUser {
        let user = try await repository.fetchCurrentUser()
        return SyncedUser(user: user, origin: .remote)
    }

    package func updateProfile(name: String) async throws -> User {
        try await repository.updateProfile(name: name)
    }
}

// MARK: - Remote first, cache as a fallback

/// The API is the source of truth; the local store is a copy of the last
/// successful answer, read only when the device cannot reach the host.
///
/// This is the app's default (`AppContainer.live(syncPolicy:)`), and it is the
/// conservative one: a read costs a request every time, so the screen is never
/// showing something older than this call unless it says so through
/// `SyncOrigin.localCache`. Phase 9 item 1 inverts it — SwiftData becomes the
/// source of truth with a refresh policy over the top — and that is a different
/// item precisely because it changes which side is authoritative rather than
/// which side is asked first.
package struct RemoteFirstSyncStrategy: SyncStrategy {
    package var policy: SyncPolicy { .remoteFirst }

    private let repository: any UserRepository
    private let store: any UserPersistenceService

    package init(repository: any UserRepository, store: any UserPersistenceService) {
        self.repository = repository
        self.store = store
    }

    package func loadCurrentUser() async throws -> SyncedUser {
        do {
            let user = try await repository.fetchCurrentUser()
            try await store.writeThrough(user)
            return SyncedUser(user: user, origin: .remote)
        } catch {
            guard SyncFailure.isOffline(error), let cached = await store.cachedUser() else {
                throw error
            }
            return SyncedUser(user: cached, origin: .localCache)
        }
    }

    /// A write-through failure propagates rather than being logged and
    /// swallowed, on both cache-backed strategies. The reasoning is that a
    /// store which cannot accept the row is a cache that will be silently
    /// useless from here on, and "the profile saved but your device did not
    /// keep it" is a state a caller should be able to see. "Log and carry on"
    /// is a policy too, and it belongs in the telemetry decorator that Phase 8
    /// item 4 adds — not hardcoded here, which is the shape of finding 7.
    package func updateProfile(name: String) async throws -> User {
        let user = try await repository.updateProfile(name: name)
        try await store.writeThrough(user)
        return user
    }
}

// MARK: - Cache first, with a freshness window

/// The local store answers while its copy is younger than `maxAge`; after that
/// the API is asked and the answer is written through.
///
/// The freshness window is measured on a monotonic clock and held in memory for
/// the life of the process, not persisted beside the row. Two reasons. A stored
/// "fetched at" column is a schema change, and versioned schemas plus migration
/// tests are Phase 9 item 4 — adding a column here would land an unversioned
/// migration in an item about a design pattern. And `ContinuousClock` does not
/// move when the wall clock does, so a device that crosses a timezone or syncs
/// its clock backwards does not get a cache that is suddenly fresh for an hour.
///
/// What it costs is stated plainly: a cold launch always goes to the network,
/// because nothing in memory says when the cached row was fetched. That is the
/// safe direction to be wrong in, and Phase 9 item 1 is where a persisted
/// timestamp belongs.
///
/// `now` is injected so the window is testable without sleeping. Phase 7 noted
/// that `withTimeout` shipped with no clock seam and that its suite therefore
/// measures real durations; this is the same lesson applied at the point the
/// code was written rather than afterwards.
package final class CacheFirstSyncStrategy: SyncStrategy {
    package var policy: SyncPolicy { .cacheFirst }

    private let repository: any UserRepository
    private let store: any UserPersistenceService
    private let maxAge: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    /// When the cache was last filled from the API, or `nil` before the first
    /// successful fetch in this process.
    private let lastRefresh = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

    package init(
        repository: any UserRepository,
        store: any UserPersistenceService,
        maxAge: Duration,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.repository = repository
        self.store = store
        self.maxAge = maxAge
        self.now = now
    }

    /// Two concurrent loads that both find the window expired both go to the
    /// network. Collapsing them is what `SingleFlightCache` is for, and wiring
    /// it in is a decorator (Phase 8 item 4) rather than a branch inside this
    /// policy — the duplicate request is a cost, not a correctness bug, because
    /// the write-through is an upsert.
    package func loadCurrentUser() async throws -> SyncedUser {
        if isWithinFreshnessWindow, let cached = await store.cachedUser() {
            return SyncedUser(user: cached, origin: .localCache)
        }

        do {
            let user = try await repository.fetchCurrentUser()
            try await store.writeThrough(user)
            lastRefresh.withLock { $0 = now() }
            return SyncedUser(user: user, origin: .remote)
        } catch {
            guard SyncFailure.isOffline(error), let cached = await store.cachedUser() else {
                throw error
            }
            return SyncedUser(user: cached, origin: .localCache)
        }
    }

    /// A successful write is a fresher answer than anything the API could
    /// return, so it restarts the window rather than leaving the next read to
    /// go and fetch what this call just sent.
    package func updateProfile(name: String) async throws -> User {
        let user = try await repository.updateProfile(name: name)
        try await store.writeThrough(user)
        lastRefresh.withLock { $0 = now() }
        return user
    }

    private var isWithinFreshnessWindow: Bool {
        guard let filled = lastRefresh.withLock({ $0 }) else { return false }
        return filled.duration(to: now()) < maxAge
    }
}
