import Foundation

/// A string that has passed this app's rules for a profile name: trimmed, not
/// blank, and no longer than ``maximumLength`` characters.
///
/// ## Why a type and not a function
///
/// The rules were three `guard`s inside `RenameProfileUseCase`, which is where
/// they were discovered and the wrong place for them to stay. A rule inside the
/// one caller that needs it is a rule the next caller restates or forgets, and
/// there are already two callers: the write, and the Save button whose
/// enablement asks the same question one layer up. `ProfileFeature.canSave`
/// used to answer it with `!candidate.isEmpty && candidate != user.name`, which
/// is the first rule and not the third — so the button was enabled for a name
/// the write would have refused.
///
/// A type, rather than a `validate(_:) throws` free function, because the
/// result is worth carrying: once a `ProfileName` exists, nothing downstream
/// has to re-check it, and a function that returns `Void` leaves the checked
/// and unchecked strings indistinguishable one line later. Normalisation is
/// part of identity here — `" Ada "` and `"Ada"` make the same value — which
/// is a property a function returning nothing cannot have.
///
/// ## What it deliberately does not decide
///
/// Whether the name is a *change*. `canSave` compares against the loaded
/// profile and declines to enable Save for a name the reader already has; that
/// needs the current user, which this type does not have and should not ask
/// for. A rule about a value and a rule about two values are different rules.
package struct ProfileName: Equatable, Sendable {

    /// The longest a name may be, in characters as a reader counts them.
    ///
    /// The app owns the ceiling rather than deferring to the server's, which is
    /// not a limit this client knows and whose rejection arrives as a status
    /// code with no field name in it — so a screen that waited for the server
    /// to object could report nothing more useful than "the save failed".
    package static let maximumLength = 50

    /// The checked name, as it should be stored and sent.
    package let value: String

    /// Checks `raw` and keeps the trimmed result.
    ///
    /// - Parameter raw: a name as somebody typed or pasted it.
    /// - Throws: ``ProfileNameError`` naming the rule `raw` broke.
    package init(validating raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileNameError.empty }
        // `count` on a `String` counts grapheme clusters: what a reader calls a
        // character and what the text cursor moves over. `utf16.count` would
        // refuse a 20-character name of family emoji as if it were 220.
        guard trimmed.count <= Self.maximumLength else {
            throw ProfileNameError.tooLong(limit: Self.maximumLength)
        }

        value = trimmed
    }
}
