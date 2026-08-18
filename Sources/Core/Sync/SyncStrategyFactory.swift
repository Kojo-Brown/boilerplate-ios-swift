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
enum SyncPolicy: String, Sendable, Equatable, CaseIterable {
    /// The API answers every read. No local copy is kept.
    case remoteOnly
    /// The API answers, the answer is cached, and the cache is read only when
    /// the device is offline.
    case remoteFirst
    /// The cache answers while it is fresh; the API answers when it is not.
    case cacheFirst
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
protocol SyncStrategyFactory: Sendable {
    func makeStrategy(for policy: SyncPolicy) -> any SyncStrategy
}

/// Binds the collaborators once and resolves a policy to a strategy on demand.
///
/// This holds the repository and the store, which is what makes it a factory
/// rather than a free function: the caller asking for a policy does not have,
/// and should not have, the graph needed to build one.
struct LiveSyncStrategyFactory: SyncStrategyFactory {

    /// How long `cacheFirst` serves the local copy before going back to the
    /// API. Five minutes is a default, not a discovery — it is short enough
    /// that a profile edited on another device shows up within a screen
    /// transition or two, and long enough that a tab switch is not a request.
    static let defaultCacheMaxAge: Duration = .seconds(300)

    private let repository: any UserRepository
    private let store: any UserPersistenceService
    private let cacheMaxAge: Duration
    private let now: @Sendable () -> ContinuousClock.Instant

    init(
        repository: any UserRepository,
        store: any UserPersistenceService,
        cacheMaxAge: Duration = LiveSyncStrategyFactory.defaultCacheMaxAge,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.repository = repository
        self.store = store
        self.cacheMaxAge = cacheMaxAge
        self.now = now
    }

    /// Each call builds a new strategy. `cacheFirst` carries a freshness window
    /// as mutable state, so vending a shared instance would let one screen's
    /// read reset another's window — and a factory whose product is a singleton
    /// is a singleton with extra steps.
    func makeStrategy(for policy: SyncPolicy) -> any SyncStrategy {
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
final class MockSyncStrategyFactory: SyncStrategyFactory {

    let stubbedStrategy: MockSyncStrategy

    private let requests = OSAllocatedUnfairLock<[SyncPolicy]>(initialState: [])

    init(stubbedStrategy: MockSyncStrategy = MockSyncStrategy()) {
        self.stubbedStrategy = stubbedStrategy
    }

    /// The policies this factory was asked for, in order.
    var requestedPolicies: [SyncPolicy] { requests.withLock { $0 } }

    func makeStrategy(for policy: SyncPolicy) -> any SyncStrategy {
        requests.withLock { $0.append(policy) }
        return stubbedStrategy
    }
}
