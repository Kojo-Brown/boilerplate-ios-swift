import Core
import Foundation

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

    /// The longest name this app will send, in characters.
    ///
    /// The app owns the ceiling rather than deferring to the server's, which is
    /// not a limit this client knows and whose rejection arrives as a status
    /// code with no field name in it — so a screen that waited for it could
    /// report nothing more useful than "the save failed".
    package static let maximumNameLength = 50

    private let strategy: any SyncStrategy

    package init(strategy: any SyncStrategy) {
        self.strategy = strategy
    }

    /// Sends `requested` as the profile's new name and returns the profile the
    /// server answered with.
    ///
    /// `requested` is what somebody typed, so it is trimmed before it is sent:
    /// a trailing space is what a thumb and iOS autocorrection produce, not an
    /// instruction, and the server has no way to tell the difference once it is
    /// stored.
    ///
    /// - Throws: ``ProfileNameError`` when `requested` is no name at all or
    ///   does not fit, in which case no request is made. Neither is something
    ///   the server refuses on this app's behalf: it stores a blank name, and
    ///   its own ceiling — whatever it is — is reported as a status code with
    ///   no field name in it.
    package func rename(to requested: String) async throws -> User {
        let name = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ProfileNameError.empty }
        // `count` on a `String` counts grapheme clusters: what a reader calls a
        // character and what the text cursor moves over. `utf16.count` would
        // refuse a 20-character name of family emoji as if it were 220.
        guard name.count <= Self.maximumNameLength else {
            throw ProfileNameError.tooLong(limit: Self.maximumNameLength)
        }

        return try await strategy.updateProfile(name: name)
    }
}
