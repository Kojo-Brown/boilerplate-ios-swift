import Core
import Foundation
import os

// MARK: - What a read produced

/// Which side of the sync answered a read.
///
/// A caller that only wanted a `User` would not need this. A caller that has to
/// tell the reader "this is what we last saw while you were online" does, and
/// hiding it inside the strategy is how an offline screen ends up silently
/// presenting stale data as live data.
package enum SyncOrigin: String, Sendable, Equatable, CaseIterable {
    /// Fetched from the API during this call.
    case remote
    /// Read from the local store, because the policy preferred it or because
    /// the network could not be reached.
    case localCache
}

/// A `User` plus the provenance of the value.
package struct SyncedUser: Sendable, Equatable {
    package let user: User
    package let origin: SyncOrigin

    package init(user: User, origin: SyncOrigin) {
        self.user = user
        self.origin = origin
    }
}

// MARK: - The strategy

/// The Strategy: how a read of the signed-in user is satisfied across a remote
/// source of truth (`UserRepository`) and a local cache
/// (`UserPersistenceService`).
///
/// Three things vary between the implementations and nothing else does: who is
/// asked first, whether the answer is written back to the cache, and what
/// happens when the network is unreachable. Those are policy, and policy is
/// what an app configures — so it lives in a substitutable object chosen once,
/// at the composition root, rather than in a `Bool` threaded through the
/// repository layer.
///
/// `docs/solid.md` finding 6 is the reason this protocol exists at all: the
/// repository layer had a constructor and no caller, so everything the audit
/// said about substituting it was a statement about code nothing ran. A
/// strategy is a caller, and `ProfileEffectHandler` is a caller of the strategy.
/// See `docs/sync-strategy.md`.
package protocol SyncStrategy: Sendable {
    /// The policy this object implements, readable back off the object the
    /// factory produced. It exists so that "the root resolved the policy it was
    /// asked for" is assertable without matching on a type name.
    var policy: SyncPolicy { get }

    /// Reads the signed-in user under this strategy's policy.
    func loadCurrentUser() async throws -> SyncedUser

    /// Writes a profile change through to the API and reconciles the cache with
    /// whatever came back.
    ///
    /// Every strategy sends the write to the API — there is no local-only
    /// policy here, because a profile edit that never leaves the device is a
    /// different feature (an outbox with conflict resolution) and it is Phase 9
    /// item 3's, not this item's.
    func updateProfile(name: String) async throws -> User
}

// MARK: - Classifying a failure

/// Whether a failure from the repository layer means "the network was not
/// reachable" — the one condition under which a cache-backed strategy is
/// allowed to answer with a stale value.
package enum SyncFailure {

    /// `true` only for a transport failure.
    ///
    /// The narrowness is the point. A 401 must not be papered over with a
    /// cached profile: the session is gone, the app has to say so, and serving
    /// the last-known user makes a signed-out app look signed in. A decoding
    /// failure is a bug, and hiding it behind the cache is how it survives to
    /// the next release. Only "the device could not reach the host" is a
    /// condition the cache is an answer to.
    ///
    /// Two error types are matched because the layer genuinely throws two.
    /// `docs/solid.md` finding 4 records that `LiveUserRepository` surfaces
    /// `APIError` while `MockUserRepository` throws `UserRepositoryError`, and
    /// that nothing reconciles them — so this is the first production code to
    /// pay for that, and it pays by knowing about both. Matching one type would
    /// mean the policy behaved differently under test than in the app, which is
    /// worse than the duplication.
    ///
    /// Phase 8 item 4 was expected to fix it, by translating errors in the
    /// decorator it put between the client and the repository. It did not, and
    /// the reason is worth recording rather than deferring again:
    /// `RetryingUserRepository` decides whether to try again by reading
    /// `APIError.httpError`'s status code and `URLError`'s code, so a
    /// translation into `UserRepositoryError`'s three cases *underneath* it
    /// would erase the evidence the policy runs on. Translating above it is
    /// possible and needs an error type that can carry a cause, which is a
    /// change to this package's error vocabulary and not a decorator around its
    /// repository. See `docs/decorators.md`.
    package static func isOffline(_ error: any Error) -> Bool {
        if let apiError = error as? APIError, case .networkUnavailable = apiError {
            return true
        }
        if let repositoryError = error as? UserRepositoryError,
           repositoryError == .networkUnavailable {
            return true
        }
        return false
    }
}

/// A `Sendable`, presentable box for whatever the repository layer threw.
///
/// `LoadingState.failure` carries `any Error & Sendable`, and its own doc
/// comment says the fix at a `catch` site is to name the concrete error type.
/// A caller of `SyncStrategy` cannot: the strategies forward failures from
/// `APIError`, `UserRepositoryError` and `PersistenceError` — `docs/solid.md`
/// finding 4 again — so naming one type would drop the other two into a
/// fallback branch and naming all three is three copies of the same handler.
///
/// This keeps the one thing a screen needs, the localized message, and says so
/// in the type rather than pretending a category was preserved. It survives
/// Phase 8 item 4, which added the decorator layer without unifying the error
/// vocabulary — see `isOffline(_:)` above for why the two pull in opposite
/// directions. Whichever item does unify them, the honest change here is to
/// delete this type and name the one that replaced it.
package struct SyncErrorMessage: LocalizedError, Sendable, Equatable {
    package let message: String

    package init(_ error: any Error) {
        message = error.localizedDescription
    }

    package var errorDescription: String? { message }
}

// MARK: - Cache operations shared by the strategies

extension UserPersistenceService {

    /// Upserts `user`: update the stored row if it is there, insert it if it is
    /// not.
    ///
    /// This is spelled at the call site rather than by fixing `save(user:)`
    /// because `docs/solid.md` finding 3 is about `save(user:)` and is assigned
    /// to Phase 9 item 1 — `SwiftDataUserPersistenceService.save(user:)`
    /// inserts, `MockUserPersistenceService.save(user:)` upserts, and choosing
    /// between them is a change to the store's contract.
    ///
    /// What this item must not do is *become* the caller that finding predicted:
    /// "a save-on-every-launch caller reads back a stable value in tests and an
    /// arbitrary one on device". Every write-through in this file goes through
    /// here, so a second load of the same user leaves one row on both
    /// implementations, and `repeatedReadsDoNotAccumulateRows` pins that
    /// against the real SwiftData store rather than the double.
    package func writeThrough(_ user: User) async throws {
        do {
            try await update(user: user)
        } catch PersistenceError.userNotFound {
            try await save(user: user)
        }
    }

    /// The cached user, or `nil` when there is none *or* the store failed.
    ///
    /// Swallowing a store error is deliberate and is scoped to one path: this
    /// is only ever called from the fallback arm of a read that has already
    /// failed because the device is offline. Rethrowing there would replace
    /// "you are offline", which the caller can act on, with a disk error it
    /// cannot. Every other call into the store in this file propagates.
    package func cachedUser() async -> User? {
        try? await fetchCurrentUser()
    }
}

// MARK: - Double

/// Records what it was asked and answers with what it was told to.
///
/// State lives in a lock rather than under `@MainActor`, following
/// `MockAPIClient` and `MockAuthService`: `docs/solid.md` finding 5 is what
/// happens when a double is actor-isolated and the type it stands in for is
/// not, and a strategy is used from view models that are already on the main
/// actor, so isolating this one would hide exactly the hop it exists to fake.
package final class MockSyncStrategy: SyncStrategy {

    private struct State: Sendable {
        var policy: SyncPolicy = .remoteOnly
        var stubbedUser = User(email: "mock@example.invalid", name: "Mock User")
        var stubbedOrigin: SyncOrigin = .remote
        var loadError: (any Error & Sendable)?
        var updateError: (any Error & Sendable)?
        var loadCount = 0
        var updateCount = 0
        var requestedNames: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package init() {}

    package var policy: SyncPolicy {
        get { state.withLock { $0.policy } }
        set { state.withLock { $0.policy = newValue } }
    }

    package var stubbedUser: User {
        get { state.withLock { $0.stubbedUser } }
        set { state.withLock { $0.stubbedUser = newValue } }
    }

    package var stubbedOrigin: SyncOrigin {
        get { state.withLock { $0.stubbedOrigin } }
        set { state.withLock { $0.stubbedOrigin = newValue } }
    }

    package var loadError: (any Error & Sendable)? {
        get { state.withLock { $0.loadError } }
        set { state.withLock { $0.loadError = newValue } }
    }

    package var updateError: (any Error & Sendable)? {
        get { state.withLock { $0.updateError } }
        set { state.withLock { $0.updateError = newValue } }
    }

    package var loadCount: Int { state.withLock { $0.loadCount } }
    package var updateCount: Int { state.withLock { $0.updateCount } }
    package var requestedNames: [String] { state.withLock { $0.requestedNames } }

    /// The whole state is snapshotted under the lock and read outside it, so
    /// the throw happens after the lock is released rather than inside the
    /// closure — `withLock`'s body is not the place to unwind from.
    package func loadCurrentUser() async throws -> SyncedUser {
        let snapshot = state.withLock { current -> State in
            current.loadCount += 1
            return current
        }
        if let error = snapshot.loadError { throw error }
        return SyncedUser(user: snapshot.stubbedUser, origin: snapshot.stubbedOrigin)
    }

    package func updateProfile(name: String) async throws -> User {
        let snapshot = state.withLock { current -> State in
            current.updateCount += 1
            current.requestedNames.append(name)
            if current.updateError == nil {
                current.stubbedUser = current.stubbedUser.with(name: .set(name))
            }
            return current
        }
        if let error = snapshot.updateError { throw error }
        return snapshot.stubbedUser
    }
}
