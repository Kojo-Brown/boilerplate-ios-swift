import Core
import Foundation

/// Renames the signed-in user's profile.
///
/// ## Why there is a type here at all
///
/// The write it performs is one line — `strategy.updateProfile(name:)` — and a
/// screen can call that line itself, which is what `ProfileEffectHandler` did.
/// What a screen cannot do is be the place a rule about profile names is
/// *applied*: `ProfileFeature.State.canSave` decides whether the Save button is
/// enabled, and a button's enablement is not an enforcement point. The effect
/// that performs the write is reachable without it, a second caller would
/// restate the rule or forget it, and neither the reducer nor the view is
/// somewhere a non-UI caller — a deep link, a migration, an onboarding step —
/// would look.
///
/// So this is where a name is checked on its way to the server, once. What a
/// valid name *is* belongs to ``ProfileName``, which is a `Core` value type
/// because the same rules decide whether the Save button is enabled; this type
/// is the one that refuses to let an unchecked string past it.
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
    ///
    /// `requested` is what somebody typed, so it is checked rather than
    /// trusted, and what reaches the server is ``ProfileName/value`` — the
    /// trimmed form — rather than the keystrokes. A trailing space is what a
    /// thumb and iOS autocorrection produce, not an instruction, and the server
    /// has no way to tell the difference once it is stored.
    ///
    /// - Throws: ``ProfileNameError`` when `requested` is no name at all or
    ///   does not fit, in which case no request is made. Neither is something
    ///   the server refuses on this app's behalf: it stores a blank name, and
    ///   its own ceiling — whatever it is — is reported as a status code with
    ///   no field name in it.
    package func rename(to requested: String) async throws -> User {
        let name = try ProfileName(validating: requested)

        return try await strategy.updateProfile(name: name.value)
    }
}
