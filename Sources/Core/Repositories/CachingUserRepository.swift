import Foundation

// MARK: - Caching decorator

/// Answers repeated profile reads from memory for a short window, and collapses
/// concurrent ones into a single request.
///
/// ## What this cache is, and what it is emphatically not
///
/// This package already has a cache: `UserPersistenceService`, the SwiftData
/// copy of the signed-in user, with `SyncStrategy` deciding when it answers and
/// when the API does. That one is durable, survives launches, and exists so the
/// app has something to show when the device is offline. Its freshness window
/// is five minutes and it is policy.
///
/// This one is neither durable nor policy. It is a de-duplication window: three
/// screens that read the profile during one navigation transition produce one
/// request instead of three, and fifty concurrent readers of a cold cache
/// produce one request rather than fifty, which is `SingleFlightCache`'s whole
/// subject. Five seconds is chosen to be far too short to substitute for the
/// strategy above it — `cacheTimeToLiveIsWellInsideTheSyncWindow` pins that
/// relationship, because the failure mode if it ever inverted would be silent:
/// `CacheFirstSyncStrategy` would decide its window had expired, go to the API
/// for a fresh value, and be answered out of this decorator's memo.
///
/// Two properties keep that window honest even inside it:
///
/// * **Failures are never memoised.** `SingleFlightCache` caches success only,
///   so an offline read fails now and fails again on the next call. Nothing
///   here can make an offline app look online for five seconds; the most it can
///   do is answer with a value the API returned less than five seconds ago.
/// * **Writes drop the memo, on both paths.** A `PATCH` that failed with a
///   timeout may still have been applied, so invalidating only on success would
///   leave the memo authoritative about a profile the server has already
///   replaced.
///
/// ## Why no write-through
///
/// `updateProfile` returns the server's representation of the user after the
/// write, which would be a perfectly good cache fill. It is discarded anyway,
/// for a reason about the primitive rather than about the value:
/// `SingleFlightCache` memoises the result of a *load* it ran, deliberately,
/// and every guarantee in it — one load per key, no resurrection of an
/// invalidated entry, no caching of failures — is stated in terms of loads it
/// owns. A `store(_:for:)` entry point would widen that contract to serve one
/// decorator, and the cost of not having it is one request after each profile
/// edit.
struct CachingUserRepository: UserRepositoryDecorator {

    /// How long a fetched profile answers subsequent reads.
    ///
    /// Read the value together with `LiveSyncStrategyFactory.defaultCacheMaxAge`,
    /// which is sixty times longer. That ratio is the design: this is a burst
    /// window, that is a staleness policy.
    static let defaultTimeToLive: Duration = .seconds(5)

    /// The one thing this decorator caches.
    ///
    /// A single-case enum rather than an implied key, so that adding a second
    /// cached operation is a switch the compiler asks about instead of a string
    /// two call sites have to keep spelling the same way.
    enum CacheKey: Hashable, Sendable {
        case currentUser
    }

    /// A cached profile and the instant it was fetched.
    ///
    /// The timestamp lives in the value rather than beside the cache because
    /// expiry is the caller's definition — see
    /// `SingleFlightCache.freshValue(for:isFresh:)`.
    struct CachedUser: Sendable {
        let user: User
        let storedAt: ContinuousClock.Instant
    }

    let base: any UserRepository

    private let cache: SingleFlightCache<CacheKey, CachedUser>
    private let timeToLive: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    /// - Parameters:
    ///   - base: The repository this one reads through to.
    ///   - timeToLive: How long a fetched value answers reads.
    ///   - now: The clock. Monotonic rather than wall-clock, and injected for
    ///     the reason `LiveSyncStrategyFactory` injects its own: a freshness
    ///     window tested with `Task.sleep` costs the suite the window.
    init(
        base: any UserRepository,
        timeToLive: Duration = CachingUserRepository.defaultTimeToLive,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        precondition(timeToLive > .zero, "timeToLive must be positive, got \(timeToLive)")
        self.base = base
        self.timeToLive = timeToLive
        self.now = now
        // Built from the parameters rather than from `self`, so the load
        // closure captures the two values it needs instead of a repository that
        // has not finished initialising.
        cache = SingleFlightCache<CacheKey, CachedUser> { _ in
            let user = try await base.fetchCurrentUser()
            return CachedUser(user: user, storedAt: now())
        }
    }

    // MARK: - UserRepository

    func fetchCurrentUser() async throws -> User {
        let timeToLive = self.timeToLive
        let now = self.now
        let cached = try await cache.freshValue(for: .currentUser) { entry in
            entry.storedAt.duration(to: now()) < timeToLive
        }
        return cached.user
    }

    func updateProfile(name: String) async throws -> User {
        let base = self.base
        return try await invalidatingCurrentUser { try await base.updateProfile(name: name) }
    }

    func deleteAccount() async throws {
        let base = self.base
        try await invalidatingCurrentUser { try await base.deleteAccount() }
    }

    // MARK: - Writes

    /// Runs a write and drops the memo whichever way it goes.
    ///
    /// The failure path is the one worth reading twice. A write that threw may
    /// still have been applied — that is the same ambiguity
    /// `RetryingUserRepository` refuses to retry through — and the two
    /// possibilities cost differently here: dropping a memo that did not need
    /// dropping costs one request, and keeping one that did costs a screen
    /// showing the profile the user just changed.
    private func invalidatingCurrentUser<Value: Sendable>(
        _ work: () async throws -> Value
    ) async throws -> Value {
        do {
            let value = try await work()
            await cache.invalidate(.currentUser)
            return value
        } catch {
            await cache.invalidate(.currentUser)
            throw error
        }
    }
}
