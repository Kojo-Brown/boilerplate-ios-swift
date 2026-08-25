import Core
import Foundation
import Networking

/// Performs the Account section's effects: the half of `ProfileFeature` that is
/// allowed to talk to the world.
///
/// It holds the three collaborators the screen used to hold — the resolved
/// strategy, the factory, and the publishing half of the event bus — and the
/// reducer beside it holds none of them, which is what makes that reducer
/// testable with no doubles at all.
///
/// It holds the factory as well as the strategy for the reason
/// `docs/sync-strategy.md` gives: the container resolves one policy for the
/// app, and a pull-to-refresh under `cacheFirst` would otherwise be answered by
/// the very cache it is trying to get past. Asking the factory for
/// `.remoteFirst` states "go to the server, but do not fail if the device is
/// offline" without this type knowing which concrete strategy that is.
///
/// A `struct`, and `Sendable` because `EffectHandling` is: `perform` runs off
/// the main actor, which is what keeps the store's `await` a real hop rather
/// than a formality.
package struct ProfileEffectHandler: EffectHandling {

    package typealias Effect = ProfileFeature.Effect
    package typealias Action = ProfileFeature.Action

    private let strategy: any SyncStrategy
    private let strategyFactory: any SyncStrategyFactory
    private let events: any EventPublishing

    package init(
        strategy: any SyncStrategy,
        strategyFactory: any SyncStrategyFactory,
        events: any EventPublishing
    ) {
        self.strategy = strategy
        self.strategyFactory = strategyFactory
        self.events = events
    }

    package func perform(_ effect: Effect) async -> Action? {
        switch effect {
        case .loadProfile:
            return await load(using: strategy)

        case .refreshProfile:
            return await load(using: strategyFactory.makeStrategy(for: .remoteFirst))

        case .saveName(let name):
            return await save(name)

        case .announceSignOut:
            events.publish(UserSignedOut())
            // The screen has nothing to say about this: `SessionObserver`
            // clears the app state and the tokens, and the root view swaps the
            // subtree away. An action back would be a fourth thing claiming to
            // know what signing out means.
            return nil
        }
    }

    // MARK: - Private

    /// Both failure branches collapse to `SyncErrorMessage` for the reason that
    /// type records: the strategies forward failures from `APIError`,
    /// `UserRepositoryError` and `PersistenceError`, so naming one of them here
    /// would drop the other two into a fallback branch.
    private func load(using strategy: any SyncStrategy) async -> Action {
        do {
            let synced = try await strategy.loadCurrentUser()
            return .profileLoaded(.success(synced))
        } catch {
            return .profileLoaded(.failure(SyncErrorMessage(error)))
        }
    }

    private func save(_ name: String) async -> Action {
        do {
            let updated = try await strategy.updateProfile(name: name)
            return .profileSaved(.success(updated))
        } catch {
            return .profileSaved(.failure(SyncErrorMessage(error)))
        }
    }
}
