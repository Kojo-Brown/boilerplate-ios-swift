import Foundation
import SwiftUI

// MARK: - Resolving a resource

extension LocalizedStringResource {

    /// This resource resolved against the current locale.
    ///
    /// `Text` has its own initialiser for a `LocalizedStringResource`, and
    /// where SwiftUI accepts a `Text` that is what the call sites pass. This is
    /// for everywhere else: `errorDescription`, `Label(_:systemImage:)` and the
    /// other SwiftUI APIs that take a `LocalizedStringKey` (which a resource is
    /// not) but also a `StringProtocol` (which this is), a `String` parameter
    /// on a UIKit or LocalAuthentication API, an interpolation into another
    /// string.
    ///
    /// Resolution happens at the point of call, which is what makes it the
    /// wrong thing to store — a value resolved once at launch would not follow
    /// a locale change, and an error built on a background task can be rendered
    /// minutes later.
    package var string: String { String(localized: self) }
}

// MARK: - This target's catalog

/// Looks a key up in `Core`'s own `Localizable.xcstrings`.
///
/// The `bundle` argument is the whole point of this function, and leaving it
/// off is the defect it exists to prevent. `Text("home.title")`,
/// `NSLocalizedString`, and `LocalizedStringResource("home.title")` all resolve
/// against **`Bundle.main`** — the *app's* bundle. A package target's catalog
/// is not in there; it is in `Bundle.module`, a separate resource bundle the
/// build copies in beside the binary. So a string declared in a package and
/// looked up the ordinary way misses, silently, and Foundation's documented
/// fallback for a missing key is to return **the key itself**. The screen then
/// renders `home.title`, in every language including the one the catalog was
/// written in.
///
/// Nothing catches that. It is not a warning, not a crash, and not visible in
/// a preview built into the same module — the failure needs the string and the
/// catalog to be in *different* bundles, which is the arrangement every call
/// site here is in. `LocalisationTests` asserts that each resource resolves to
/// something other than its own key, which is the assertion that fails if this
/// argument is ever dropped.
///
/// `table:` is named explicitly for the same reason: the default is
/// `Localizable`, and relying on a default that a second catalog would change
/// is not worth the saved characters.
private func coreString(
    _ key: String.LocalizationValue,
    _ comment: StaticString
) -> LocalizedStringResource {
    LocalizedStringResource(
        key,
        table: "Localizable",
        bundle: .atURL(Bundle.module.bundleURL),
        comment: comment
    )
}

// MARK: - Strings

/// Every string `Core` shows to somebody, in one place.
///
/// A namespace rather than scattered literals, for three reasons that are not
/// about tidiness:
///
/// * **A key used nowhere and a key missing from the catalog are both
///   findable.** `Tools/assert-localisation.py` reads these files and the
///   catalog and fails on either, which is the check Xcode's own extraction
///   performs for an app target and does not perform for a package.
/// * **The comment travels with the string.** A translator sees "Dark" with no
///   idea whether it is a colour, a roast or an appearance setting; the comment
///   is the one thing that reaches them alongside it.
/// * **One string, one key.** "No network connection." is shown by two
///   different errors in two targets, and a literal in each is two entries a
///   translator pays for twice and can answer differently.
///
/// Every member is a computed property rather than a stored `static let`. That
/// is deliberate: a stored static is global mutable state as far as Swift 6
/// concurrency checking is concerned unless its type is provably `Sendable`,
/// and a resource costs nothing to rebuild.
package enum CoreStrings {

    // MARK: Appearance

    /// The name of an appearance option, as the settings picker shows it.
    package static func appearance(_ scheme: AppColorScheme) -> LocalizedStringResource {
        switch scheme {
        case .system: coreString("appearance.system", "Appearance option: follow the device setting.")
        case .light:  coreString("appearance.light", "Appearance option: always use the light appearance.")
        case .dark:   coreString("appearance.dark", "Appearance option: always use the dark appearance.")
        }
    }

    // MARK: API errors

    package enum API {

        package static var invalidURL: LocalizedStringResource {
            coreString("error.api.invalidURL", "The request could not be turned into a URL.")
        }

        package static var invalidResponse: LocalizedStringResource {
            coreString("error.api.invalidResponse", "The server answered with something unusable.")
        }

        package static var unauthorized: LocalizedStringResource {
            coreString("error.api.unauthorized", "The request was rejected for lack of a valid credential.")
        }

        package static var tokenRefreshFailed: LocalizedStringResource {
            coreString("error.api.tokenRefreshFailed", "The refresh token was rejected.")
        }

        /// - Parameter code: the failing HTTP status.
        package static func httpStatus(_ code: Int) -> LocalizedStringResource {
            coreString("error.api.httpStatus \(code)", "%lld is the failing HTTP status code.")
        }

        /// - Parameter reason: the decoder's own message.
        package static func decodingFailed(_ reason: String) -> LocalizedStringResource {
            coreString("error.api.decodingFailed \(reason)", "%@ is the decoder's own message.")
        }
    }

    // MARK: Biometrics

    package enum Biometrics {

        package static var notAvailable: LocalizedStringResource {
            coreString("error.biometrics.notAvailable", "No biometric hardware, or it is unusable.")
        }

        package static var notEnrolled: LocalizedStringResource {
            coreString("error.biometrics.notEnrolled", "Hardware present, nothing registered against it.")
        }

        package static var userCancelled: LocalizedStringResource {
            coreString("error.biometrics.userCancelled", "The reader dismissed the prompt.")
        }

        package static var userFallback: LocalizedStringResource {
            coreString("error.biometrics.userFallback", "The reader chose the passcode route instead.")
        }

        package static var systemCancelled: LocalizedStringResource {
            coreString("error.biometrics.systemCancelled", "The OS took the prompt away.")
        }

        package static var passcodeNotSet: LocalizedStringResource {
            coreString("error.biometrics.passcodeNotSet", "Biometrics need a passcode behind them.")
        }

        package static var lockout: LocalizedStringResource {
            coreString("error.biometrics.lockout", "Too many failed attempts; passcode only.")
        }
    }

    // MARK: Pagination

    package enum Pagination {

        package static var moreItemsPromisedWithoutCursor: LocalizedStringResource {
            coreString(
                "error.pagination.moreItemsPromisedWithoutCursor",
                "More rows are promised with no way to ask for them."
            )
        }

        package static var unusableCursor: LocalizedStringResource {
            coreString("error.pagination.unusableCursor", "The cursor failed validation.")
        }

        package static var cursorDidNotAdvance: LocalizedStringResource {
            coreString("error.pagination.cursorDidNotAdvance", "The cursor came back unchanged.")
        }

        /// - Parameter limit: how many empty pages in a row were tolerated.
        ///   Pluralised in the catalog rather than here — see
        ///   `docs/localisation.md`.
        package static func emptyPageLimit(_ limit: Int) -> LocalizedStringResource {
            coreString("error.pagination.emptyPageLimit \(limit)", "%lld empty pages in a row were tolerated.")
        }
    }

    // MARK: Persistence

    package enum Persistence {

        package static var userNotFound: LocalizedStringResource {
            coreString("error.persistence.userNotFound", "Nothing for this user in the on-device store.")
        }

        package static var staleServerCopy: LocalizedStringResource {
            coreString("error.merge.staleServerCopy", "The server answered a save with an older revision.")
        }
    }
}
