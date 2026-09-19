import Core
import Foundation

// MARK: - This target's catalog

/// Looks a key up in `Networking`'s own `Localizable.xcstrings`.
///
/// Three keys is a small catalog to give a target of its own, and the
/// alternative — putting them in `Core`'s and reaching across — does not work:
/// `Bundle.module` is generated per target and resolves to the resource bundle
/// of the module it is *compiled into*, so `Core`'s catalog is reachable only
/// from `Core`. A lookup from here against `Core`'s bundle would need `Core` to
/// vend its bundle publicly, which is a wider hole than a second catalog.
///
/// See ``CoreStrings`` for why the `bundle` argument is the load-bearing part.
private func networkingString(
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

/// Every string `Networking` shows to somebody.
package enum NetworkingStrings {

    package enum UserRepository {

        package static var notFound: LocalizedStringResource {
            networkingString("error.user.notFound", "The server has no profile for this account.")
        }

        package static var unauthorized: LocalizedStringResource {
            networkingString("error.user.unauthorized", "The profile request needs a signed-in session.")
        }

        package static var networkUnavailable: LocalizedStringResource {
            networkingString("error.user.networkUnavailable", "The request never reached the server.")
        }
    }
}
