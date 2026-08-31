import Core
import Foundation
import os

// MARK: - The policy

/// The set of sync policies this app knows how to run.
///
/// A closed enum rather than an open registry, for the same reason
/// `AppContainer` is a struct of stored properties rather than a type-keyed
/// dictionary: every value here has a conformer, the compiler checks that the
/// factory's `switch` still covers all of them, and adding a policy is a build
/// failure at the one place that has to answer for it.
///
/// The raw value exists so a policy can be read out of a launch argument or a
/// debug menu without a hand-written mapping. Nothing does that yet; the value
/// is one line and the alternative is a second copy of these names.
package enum SyncPolicy: String, Sendable, Equatable, CaseIterable {
    /// The API answers every read. No local copy is kept.
    case remoteOnly
    /// The API answers, the answer is cached, and the cache is read only when
    /// the device is offline.
    case remoteFirst
    /// The cache answers while it is fresh; the API answers when it is not.
    /// The window lives in memory, so the first read after launch is a request.
    case cacheFirst
    /// The local store is the source of truth. It answers while its row is
    /// fresh, the API refreshes the row when it is not, and the freshness is
    /// recorded on the row — so a launch inside the window costs no request.
    case offlineFirst
}

// MARK: - The factory

/// The Factory: builds the strategy object for a policy.
///
/// The seam is worth having separately from the strategy because two callers
/// want different things from it. `AppContainer` resolves the app's *declared*
/// policy once, at startup, and hands the resulting strategy to whatever needs
/// a read. A screen with an explicit "refresh" gesture wants a different policy
/// for that one call — a pull-to-refresh that returns the cache because the
/// cache is fresh is a broken gesture — and asking the factory is how it says
/// so without knowing which types implement what.
package protocol SyncStrategyFactory: Sendable {
    func makeStrategy(for policy: SyncPolicy) -> any SyncStrategy
}

/// Binds the collaborators once and resolves a policy to a strategy on demand.
///
/// This holds the repository and the store, which is what makes it a factory
/// rather than a free function: the caller asking for a policy does not have,
/// and should not have, the graph needed to build one.
package struct LiveSyncStrategyFactory: SyncStrategyFactory {

    /// How long `cacheFirst` serves the local copy before going back to the
    /// API. Five minutes is a default, not a discovery — it is short enough
    /// that a profile edited on another device shows up within a screen
    /// transition or two, and long enough that a tab switch is not a request.
    package static let defaultCacheMaxAge: Duration = .seconds(300)

    private let repository: any UserRepository
    private let store: any UserPersistenceService
    private let cacheMaxAge: Duration
    private let mergePolicy: any UserMergePolicy
    private let now: @Sendable () -> ContinuousClock.Instant
    private let date: @Sendable () -> Date

    /// - Parameters:
    ///   - cacheMaxAge: The freshness window, shared by `cacheFirst` and
    ///     `offlineFirst`. One value rather than two because it answers one
    ///     question — how stale a profile may be before it is worth a request —
    ///     and the policies differ in where they record the answer, not in what
    ///     it should be.
    ///   - mergePolicy: How `offlineFirst` orders a fetched copy of the user
    ///     against the stored one. It is held here rather than constructed in
    ///     the `switch` so that an app adopting this boilerplate replaces the
    ///     rule at the composition root, which is the only place that is
    ///     supposed to know which implementation of anything is live.
    ///   - now: The monotonic clock `cacheFirst` measures its in-memory window
    ///     with.
    ///   - date: The wall clock `offlineFirst` stamps rows with. Two clocks
    ///     because the two windows are stored in different places and only one
    ///     of them has to mean anything to the next launch — see `StoredUser`.
    package init(
        repository: any UserRepository,
        store: any UserPersistenceService,
        cacheMaxAge: Duration = LiveSyncStrategyFactory.defaultCacheMaxAge,
        mergePolicy: any UserMergePolicy = LastWriterWinsMergePolicy(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        date: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.store = store
        self.cacheMaxAge = cacheMaxAge
        self.mergePolicy = mergePolicy
        self.now = now
        self.date = date
    }

    /// Each call builds a new strategy. `cacheFirst` carries a freshness window
    /// as mutable state, so vending a shared instance would let one screen's
    /// read reset another's window — and a factory whose product is a singleton
    /// is a singleton with extra steps.
    package func makeStrategy(for policy: SyncPolicy) -> any SyncStrategy {
        // Written with explicit `return`s rather than as a `switch` expression:
        // the branches are three different concrete types and only the
        // function's return type erases them to one, which is exactly the case
        // where a value-producing `switch` is doing type inference a reader has
        // to work out.
        switch policy {
        case .remoteOnly:
            return RemoteOnlySyncStrategy(repository: repository)
        case .remoteFirst:
            return RemoteFirstSyncStrategy(repository: repository, store: store)
        case .cacheFirst:
            return CacheFirstSyncStrategy(
                repository: repository,
                store: store,
                maxAge: cacheMaxAge,
                now: now
            )
        case .offlineFirst:
            return OfflineFirstSyncStrategy(
                repository: repository,
                store: store,
                maxAge: cacheMaxAge,
                mergePolicy: mergePolicy,
                now: date
            )
        }
    }
}

// MARK: - Double

/// Hands back one strategy whatever it is asked for, and records what it was
/// asked.
///
/// The recording is the interesting half: it is how a test asserts that a
/// refresh gesture asked for `.remoteFirst` rather than reusing the container's
/// resolved strategy, which is a claim about the call site and not about the
/// strategies themselves.
package final class MockSyncStrategyFactory: SyncStrategyFactory {

    package let stubbedStrategy: MockSyncStrategy

    private let requests = OSAllocatedUnfairLock<[SyncPolicy]>(initialState: [])

    package init(stubbedStrategy: MockSyncStrategy = MockSyncStrategy()) {
        self.stubbedStrategy = stubbedStrategy
    }

    /// The policies this factory was asked for, in order.
    package var requestedPolicies: [SyncPolicy] { requests.withLock { $0 } }

    package func makeStrategy(for policy: SyncPolicy) -> any SyncStrategy {
        requests.withLock { $0.append(policy) }
        return stubbedStrategy
    }
}
