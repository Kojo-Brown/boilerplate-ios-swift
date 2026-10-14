import Core

/// Renames the signed-in user's profile.
///
/// ## Why there is a type here at all
///
/// The write it performs is one line — `strategy.updateProfile(name:)` — and a
/// screen can call that line itself, which is what `ProfileEffectHandler` did.
/// What a screen cannot do is be the place a rule about profile names lives:
/// `ProfileFeature.State.canSave` decides whether the Save button is enabled,
/// and a button's enablement is not an enforcement point. The effect that
/// performs the write is reachable without it, a second caller would restate
/// the rule or forget it, and neither the reducer nor the view is somewhere a
/// non-UI caller — a deep link, a migration, an onboarding step — would look.
///
/// So this is where "what may be sent as a name" is decided, once, between the
/// screen and the strategy.
///
/// ## Why it lives in `Networking`
///
/// It composes `SyncStrategy`, which lives here, and `Features` has no home
/// that two features could share without one of them importing the other —
/// which `Tools/assert-module-boundaries.py` forbids and the package graph is
/// shaped to prevent. A use-case over the repository layer is the same kind of
/// thing as the strategies and the decorator chain beside it: policy above the
/// transport, below the screen.
package struct RenameProfileUseCase: Sendable {

    private let strategy: any SyncStrategy

    package init(strategy: any SyncStrategy) {
        self.strategy = strategy
    }

    /// Sends `requested` as the profile's new name and returns the profile the
    /// server answered with.
    package func rename(to requested: String) async throws -> User {
        try await strategy.updateProfile(name: requested)
    }
}
