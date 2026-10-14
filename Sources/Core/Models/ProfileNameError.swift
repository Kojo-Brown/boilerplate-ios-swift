import Foundation

/// Why a string was refused as a profile name.
///
/// It is in `Core` rather than beside the use-case that throws it because a
/// rule about what a name may be is domain vocabulary: the same rule is the
/// reason the Save button is disabled, the reason a write is refused, and the
/// reason an imported or deep-linked name would be. `Core` is where this
/// package keeps the vocabulary every layer above it shares — see ``APIError``
/// and ``PersistenceError`` for the two it already kept.
///
/// `LocalizedError`, so that what reaches the reader is a sentence rather than
/// a case name: `SyncErrorMessage` boxes whatever the write threw by reading
/// `localizedDescription`, which is `errorDescription` for a `LocalizedError`
/// and the useless `"The operation couldn’t be completed"` for anything else.
///
/// `Equatable` so a test can say which rule was broken. The thrown value is
/// the only evidence of that: the message is localised, so asserting on it
/// would be asserting on a translation.
package enum ProfileNameError: LocalizedError, Equatable {

    /// Nothing but whitespace, which the server accepts and the profile row
    /// then renders as a blank the reader cannot see in order to replace.
    case empty

    package var errorDescription: String? {
        switch self {
        case .empty: CoreStrings.ProfileName.empty.string
        }
    }
}
