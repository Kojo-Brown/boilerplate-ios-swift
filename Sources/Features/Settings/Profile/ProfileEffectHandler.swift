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
/// app, and a pull-to-refresh under `cacheFirst` — or, since Phase 9 item 1,
/// under the app's `offlineFirst` default — would otherwise be answered by the
/// very stored row it is trying to get past. Asking the factory for
/// `.remoteFirst` states "go to the server, but do not fail if the device is
/// offline" without this type knowing which concrete strategy that is.
///
/// That the refresh writes through means it also restamps the row, so a gesture
/// that got past the window leaves the window closed behind it rather than
/// costing the next read a second request.
///
/// The write does not go to the strategy directly. It goes through
/// ``RenameProfileUseCase``, which is where a name is checked, because this
/// type is reachable without the button that was supposed to have checked it:
/// `perform(.saveName(_:))` is a method, and `ProfileFeature.State.canSave`
/// governs a `disabled` modifier. The read has no equivalent rule and so has no
/// equivalent indirection.
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

    /// Built from the same strategy rather than injected beside it: there is
    /// one write path here, and a second constructor parameter would let a
    /// caller point the read and the write at different servers.
    private let renameProfile: RenameProfileUseCase

    package init(
        strategy: any SyncStrategy,
        strategyFactory: any SyncStrategyFactory,
        events: any EventPublishing
    ) {
        self.strategy = strategy
        self.strategyFactory = strategyFactory
        self.events = events
        renameProfile = RenameProfileUseCase(strategy: strategy)
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

    /// `ProfileNameError` lands in the same `catch` as a transport failure and
    /// the same `SyncErrorMessage` box, which is right rather than merely
    /// convenient: the screen renders one `saveErrorMessage`, and "Enter a
    /// name." is as much an answer to "why did my save not happen" as "The
    /// request never reached the server." is. Both are `LocalizedError`, so
    /// both arrive as a sentence.
    private func save(_ name: String) async -> Action {
        do {
            let updated = try await renameProfile.rename(to: name)
            return .profileSaved(.success(updated))
        } catch {
            return .profileSaved(.failure(SyncErrorMessage(error)))
        }
    }
}
