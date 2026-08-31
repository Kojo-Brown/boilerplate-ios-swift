import Core
import Foundation

// MARK: - Offline first

/// SwiftData is the source of truth; the network is a refresh over the top of
/// it.
///
/// ## What "source of truth" changes
///
/// The other three policies in this package treat the API as authoritative and
/// the store as a copy of its last answer. Read them and you can see it in the
/// shape of the code: the request comes first, and the store is consulted in a
/// `catch`. This one inverts the two. The read starts at the store, the store's
/// stamp decides whether a request happens at all, and the value a caller gets
/// back after a successful refresh is the row that was written — not the
/// response that produced it. See `persist(_:at:)` for why that distinction is
/// load-bearing rather than pedantic.
///
/// Three properties follow, and each of them is something `cacheFirst` cannot
/// do:
///
/// **A cold launch inside the window makes no request.** `CacheFirstSyncStrategy`
/// holds its last-refresh instant in memory for the life of the process, and
/// its own documentation states the cost plainly: the first read after launch
/// always goes to the network, because nothing says when the row was fetched.
/// Here the stamp is a column, so the second launch of the app half a minute
/// after the first shows the profile with the radio idle.
///
/// **The strategy is a value with no state.** `CacheFirstSyncStrategy` is a
/// `final class` holding a lock around a mutable instant, and the factory has
/// to vend a fresh instance per call so that one screen's read cannot reset
/// another's window. This is a `struct`, because everything it would have
/// remembered is on disk. Two instances built over the same store share a
/// window automatically, which is the correct behaviour and not a coincidence.
///
/// **A failed refresh is not a failed read.** When there is a row, an offline
/// refresh returns it. The read only fails when the device has never
/// successfully synced, which is the one state an offline-first app genuinely
/// has nothing to show for.
///
/// ## What it does not soften
///
/// Only a transport failure falls back to the row — `SyncFailure.isOffline(_:)`,
/// unchanged and deliberately not widened for this policy. A 401 still
/// propagates: the session is gone, and answering it out of the store is how a
/// signed-out app goes on looking signed in. Being the source of truth is a
/// claim about *where a value comes from*, not a licence to serve it after the
/// server has said the caller may not have it.
///
/// A store failure on the primary read also propagates rather than falling
/// through to the network. Under this policy a store that cannot be read is a
/// failed read: quietly answering from the API would turn the one policy that
/// promises a durable answer into `remoteOnly` at exactly the moment a reader
/// would most want to be told.
///
/// ## The merge
///
/// Being the source of truth is also what gives this policy something to
/// arbitrate. The other three write every response over the row because the
/// response *is* the truth by definition; here the row is a claim of its own,
/// so a fetched value and a stored one can disagree about which is newer and
/// something has to say. `UserMergePolicy` says, on a server-assigned revision
/// with a wall-clock fallback, and a rejected response leaves the row intact —
/// see `docs/conflict-resolution.md` for the rules and what they cost.
package struct OfflineFirstSyncStrategy: SyncStrategy {

    package var policy: SyncPolicy { .offlineFirst }

    private let repository: any UserRepository
    private let store: any UserPersistenceService
    private let maxAge: Duration
    private let mergePolicy: any UserMergePolicy
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - repository: The network leg, asked only when the row is stale.
    ///   - store: The source of truth.
    ///   - maxAge: How old a confirmed row may be before a read refreshes it.
    ///   - mergePolicy: Which of two copies of the user wins when a response
    ///     and the row disagree. This policy is the only one that needs one:
    ///     the other three treat the API as authoritative by definition, so
    ///     there is no second claim for a rule to arbitrate between. See
    ///     `docs/conflict-resolution.md`.
    ///   - now: The wall clock. Wall rather than monotonic because the stamp it
    ///     is compared against outlives the process — see `StoredUser` — and
    ///     injected because a freshness window tested with `Task.sleep` costs
    ///     the suite the window.
    package init(
        repository: any UserRepository,
        store: any UserPersistenceService,
        maxAge: Duration,
        mergePolicy: any UserMergePolicy = LastWriterWinsMergePolicy(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.store = store
        self.maxAge = maxAge
        self.mergePolicy = mergePolicy
        self.now = now
    }

    // MARK: - Reads

    package func loadCurrentUser() async throws -> SyncedUser {
        // One reading of the clock for the whole call: the instant the window is
        // measured against and the instant a refresh is stamped with are the
        // same moment, so a read cannot decide a row is stale and then stamp
        // its replacement as if time had passed in between.
        let instant = now()
        let stored = try await store.fetchCurrentRecord()

        if let stored, stored.isFresh(at: instant, maxAge: maxAge) {
            return SyncedUser(user: stored.user, origin: .localCache)
        }

        do {
            let fetched = try await repository.fetchCurrentUser()

            // The one place in this package where two claims about the same
            // profile meet. Until this item the response won unconditionally,
            // which is correct exactly while the API is the source of truth —
            // and this policy is the one that says it is not. A response the
            // policy rejects is an *older* copy of the row, so writing it would
            // roll the profile back and then stamp the rollback as confirmed.
            //
            // The row is re-persisted rather than merely returned: the exchange
            // did happen, and re-stamping it is what stops a server that is
            // behind from being re-asked on every read for as long as it stays
            // behind. `persist` is an upsert of the value already on disk, so
            // the write changes nothing but the stamp.
            if let stored, !mergePolicy.decide(local: stored, remote: fetched).acceptsRemote {
                let kept = try await persist(stored.user, at: instant)
                return SyncedUser(user: kept, origin: .localCache)
            }

            let persisted = try await persist(fetched, at: instant)
            return SyncedUser(user: persisted, origin: .remote)
        } catch {
            guard SyncFailure.isOffline(error), let stored else { throw error }
            return SyncedUser(user: stored.user, origin: .localCache)
        }
    }

    // MARK: - Writes

    /// Sends the edit to the API and returns what the store then holds.
    ///
    /// There is no local-only write here, and the absence is the same one
    /// `SyncStrategy` documents for every policy: an edit that never leaves the
    /// device needs an outbox and a merge rule, which are Phase 9 items 3 and 5.
    /// Being offline-first about *reads* does not make a queued write free.
    ///
    /// A successful write is a fresher confirmation than any read could produce,
    /// so it restamps the row. The next read inside the window therefore serves
    /// what this call just saved rather than going back to ask about it.
    ///
    /// The response still goes through the merge policy, and a rejection here
    /// is an error rather than the quiet fallback a read gets. The asymmetry is
    /// the point: a read that rejects a response still has the row to hand
    /// back, and a write does not — the caller asked for a change, and a server
    /// answering with a revision older than the one on disk has not applied it
    /// to the profile the caller was looking at. Returning the row would report
    /// success for a write that did not happen; returning the response would
    /// roll the profile back to satisfy a request that made it newer. Failing
    /// says the only true thing.
    ///
    /// The row is looked up by the response's `id` rather than through
    /// `fetchCurrentRecord()`, for the reason `persist(_:at:)` gives: "who is
    /// current" is a question this store answers by `createdAt`, and it can
    /// still answer it with a previous account's row.
    package func updateProfile(name: String) async throws -> User {
        let updated = try await repository.updateProfile(name: name)
        let stored = try await store.fetchRecord(userId: updated.id)
        let decision = mergePolicy.decide(local: stored, remote: updated)

        guard decision.acceptsRemote else {
            throw MergeConflictError(
                decision: decision,
                storedVersion: stored?.user.version,
                fetchedVersion: updated.version
            )
        }

        return try await persist(updated, at: now())
    }

    // MARK: - The write-and-read-back

    /// Writes `user` to the store, stamps it, and returns the row that came
    /// back out.
    ///
    /// Returning `user` directly would be one call cheaper and would quietly
    /// break the promise in the type's name. If the store drops a field on the
    /// way in — which it did until this item: `update(user:)` wrote three of
    /// the five mapped columns — then a caller handed the response back reads
    /// the *server's* value while every later launch reads the truncated row.
    /// That is a bug that only shows up after the app is relaunched, which is
    /// the worst kind to own. Reading back means the value on screen is the
    /// value on disk, in the same call, or the read fails.
    ///
    /// The lookup is by `id` rather than through `fetchCurrentRecord()`,
    /// because "the current user" is a question the store answers by
    /// `createdAt` — and nothing clears this store on sign-out yet, so a
    /// previous account's row can still be in it and can still be the newest.
    /// Naming the row that was just written sidesteps that entirely.
    private func persist(_ user: User, at instant: Date) async throws -> User {
        try await store.writeThrough(user, confirmedAt: instant)
        guard let stored = try await store.fetchRecord(userId: user.id) else {
            throw PersistenceError.userNotFound
        }
        return stored.user
    }
}
