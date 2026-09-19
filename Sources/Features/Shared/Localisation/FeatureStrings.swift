import Core
import Foundation

// MARK: - This target's catalog

/// Looks a key up in `Features`' own `Localizable.xcstrings`.
///
/// Internal rather than file-private because the error vocabulary lives in
/// `FeatureStrings+Errors.swift`: splitting the namespace across two files is
/// what keeps either of them under the 500-line ceiling `.swiftlint.yml` sets,
/// and both ends have to reach the same bundle.
///
/// See ``CoreStrings`` for why the `bundle` argument is the load-bearing part
/// of this — in short, every ordinary lookup resolves against `Bundle.main`,
/// a package's catalog is not in `Bundle.main`, and a missed lookup renders
/// the key.
func featureString(
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

/// Every string the screens in `Features` show to somebody.
///
/// Grouped by screen, except where two screens genuinely show the same
/// sentence: the camera-permission banner is identical on both scanners and is
/// one key, because two keys would be two entries a translator pays for twice
/// and can answer differently.
///
/// Members are computed rather than stored for the reason recorded on
/// ``CoreStrings``.
package enum FeatureStrings {

    // MARK: Home

    package enum Home {

        package static var title: LocalizedStringResource {
            featureString("home.title", "Navigation title of the home screen.")
        }

        package static var searchPrompt: LocalizedStringResource {
            featureString("home.searchPrompt", "Placeholder in the home screen's search field.")
        }

        package static var refreshing: LocalizedStringResource {
            featureString("home.refreshing", "VoiceOver label for the toolbar spinner during a refresh.")
        }

        package static var scanText: LocalizedStringResource {
            featureString("home.menu.scanText", "Overflow menu item opening the text scanner.")
        }

        package static var scanBarcode: LocalizedStringResource {
            featureString("home.menu.scanBarcode", "Overflow menu item opening the barcode scanner.")
        }

        package static var settings: LocalizedStringResource {
            featureString("home.menu.settings", "Overflow menu item opening the settings screen.")
        }

        package static var moreOptions: LocalizedStringResource {
            featureString("home.menu.more", "VoiceOver label for the toolbar's overflow menu.")
        }

        package static var loading: LocalizedStringResource {
            featureString("home.loading", "Shown while the first page of items is in flight.")
        }

        package static var openItemHint: LocalizedStringResource {
            featureString("home.item.openHint", "VoiceOver hint on a row: where activating it leads.")
        }

        package static var errorTitle: LocalizedStringResource {
            featureString("home.error.title", "Title of the failure state on the home screen.")
        }

        package static var retry: LocalizedStringResource {
            featureString("home.error.retry", "Button that re-runs the failed load.")
        }

        package static var emptyTitle: LocalizedStringResource {
            featureString("home.empty.title", "Title of the empty state on the home screen.")
        }

        package static var emptyDescription: LocalizedStringResource {
            featureString("home.empty.description", "Body of the empty state on the home screen.")
        }
    }

    // MARK: Item detail

    package enum ItemDetail {

        package static var section: LocalizedStringResource {
            featureString("itemDetail.section", "Section header above an item's fields.")
        }

        package static var title: LocalizedStringResource {
            featureString("itemDetail.title", "Row naming the item's title.")
        }

        package static var identifier: LocalizedStringResource {
            featureString("itemDetail.id", "Row naming the item's identifier.")
        }
    }

    // MARK: Login

    package enum Login {

        package static var signIn: LocalizedStringResource {
            featureString("login.signIn", "The sign-in button, and the screen's navigation title.")
        }

        package static var heading: LocalizedStringResource {
            featureString("login.heading", "The app's name, as a heading above the sign-in form.")
        }

        package static var email: LocalizedStringResource {
            featureString("login.email", "Email field: its placeholder and its VoiceOver label.")
        }

        package static var passwordPlaceholder: LocalizedStringResource {
            featureString("login.passwordPlaceholder", "Placeholder in the password field.")
        }

        package static var password: LocalizedStringResource {
            featureString("login.password", "VoiceOver label for the password field.")
        }

        package static var passwordHint: LocalizedStringResource {
            featureString("login.passwordHint", "VoiceOver hint stating the password rule.")
        }

        package static var signingIn: LocalizedStringResource {
            featureString("login.signingIn", "Accessibility value mid-request. Present participle.")
        }

        package static var dividerOr: LocalizedStringResource {
            featureString("login.dividerOr", "The word between the two rules above the social buttons.")
        }

        package static var dividerLabel: LocalizedStringResource {
            featureString("login.dividerLabel", "VoiceOver label for that rule-or-rule divider.")
        }
    }

    // MARK: Biometrics

    package enum Biometric {

        package static var reason: LocalizedStringResource {
            featureString("biometric.reason", "Shown by the system inside the Face ID / Touch ID prompt.")
        }

        package static var faceID: LocalizedStringResource {
            featureString("biometric.faceID", "Button that starts Face ID sign-in.")
        }

        package static var touchID: LocalizedStringResource {
            featureString("biometric.touchID", "Button that starts Touch ID sign-in.")
        }

        package static var unavailable: LocalizedStringResource {
            featureString("biometric.unavailable", "Button title when there is no usable biometric hardware.")
        }

        package static var authenticating: LocalizedStringResource {
            featureString("biometric.authenticating", "Accessibility value while the prompt is up.")
        }
    }

    // MARK: Settings

    package enum Settings {

        package static var title: LocalizedStringResource {
            featureString("settings.title", "Navigation title of the settings screen.")
        }

        package static var accountSection: LocalizedStringResource {
            featureString("settings.section.account", "Section header above the account rows.")
        }

        package static var appearanceSection: LocalizedStringResource {
            featureString("settings.section.appearance", "Section header above the appearance picker.")
        }

        package static var appSection: LocalizedStringResource {
            featureString("settings.section.app", "Section header above the version and build rows.")
        }

        package static var signOut: LocalizedStringResource {
            featureString("settings.signOut", "Destructive button that ends the session.")
        }

        package static var version: LocalizedStringResource {
            featureString("settings.version", "Row naming the marketing version.")
        }

        package static var build: LocalizedStringResource {
            featureString("settings.build", "Row naming the build number.")
        }

        package static var email: LocalizedStringResource {
            featureString("settings.email", "Row naming the signed-in account's email address.")
        }

        package static var name: LocalizedStringResource {
            featureString("settings.name", "Placeholder in the editable display-name field.")
        }

        package static var save: LocalizedStringResource {
            featureString("settings.save", "Button that commits the edited display name.")
        }

        package static var saving: LocalizedStringResource {
            featureString("settings.saving", "VoiceOver label for the spinner replacing Save.")
        }

        package static var loadingProfile: LocalizedStringResource {
            featureString("settings.loadingProfile", "Shown beside a spinner while the profile loads.")
        }

        package static var loadingProfileLabel: LocalizedStringResource {
            featureString("settings.loadingProfileLabel", "VoiceOver label for that combined element.")
        }

        package static var offlineCopy: LocalizedStringResource {
            featureString("settings.offlineCopy", "Shown when the profile came from the on-device store.")
        }

        /// The footer under the appearance picker, which says what the chosen
        /// option does.
        package static func appearanceFooter(_ scheme: AppColorScheme) -> LocalizedStringResource {
            switch scheme {
            case .system:
                featureString("settings.appearance.footer.system", "Footer for the system appearance option.")
            case .light:
                featureString("settings.appearance.footer.light", "Footer for the light appearance option.")
            case .dark:
                featureString("settings.appearance.footer.dark", "Footer for the dark appearance option.")
            }
        }
    }

    // MARK: Camera permission, shared by both scanners

    package enum CameraPermission {

        package static var title: LocalizedStringResource {
            featureString("camera.permission.title", "Heading of the camera-permission banner.")
        }

        package static var body: LocalizedStringResource {
            featureString("camera.permission.body", "Says where the camera switch lives in Settings.")
        }

        package static var openSettings: LocalizedStringResource {
            featureString("camera.permission.openSettings", "Button that opens this app's page in Settings.")
        }
    }

    // MARK: Scanners

    package enum Scanner {

        package static var copy: LocalizedStringResource {
            featureString("scanner.copy", "Button that copies the scan result to the clipboard.")
        }

        package static var copied: LocalizedStringResource {
            featureString("scanner.copied", "The copy button just after it copied.")
        }

        package static var clearText: LocalizedStringResource {
            featureString("scanner.clearText", "VoiceOver label for the clear-recognised-text button.")
        }

        package static var clearCodes: LocalizedStringResource {
            featureString("scanner.clearCodes", "VoiceOver label for the clear-scanned-codes button.")
        }

        package static var pause: LocalizedStringResource {
            featureString("scanner.pause", "Toolbar button while scanning. A verb.")
        }

        package static var start: LocalizedStringResource {
            featureString("scanner.start", "Toolbar button while paused. A verb.")
        }
    }

    package enum TextScanner {

        package static var title: LocalizedStringResource {
            featureString("textScanner.title", "Navigation title of the text scanner.")
        }

        package static var rotorName: LocalizedStringResource {
            featureString("textScanner.rotor.textBlocks", "Name of the rotor that moves between blocks.")
        }

        /// - Parameter count: how many blocks the pass found. Pluralised in the
        ///   catalog, which is the only place that can get it right in a
        ///   language with more than two forms.
        package static func blocksDetected(_ count: Int) -> LocalizedStringResource {
            featureString("textScanner.blocksDetected \(count)", "%lld is how many blocks were found.")
        }
    }

    package enum BarcodeScanner {

        package static var title: LocalizedStringResource {
            featureString("barcodeScanner.title", "Navigation title of the barcode scanner.")
        }

        /// - Parameter count: how many codes the pass found. Pluralised in the
        ///   catalog — see ``TextScanner/blocksDetected(_:)``.
        package static func codesDetected(_ count: Int) -> LocalizedStringResource {
            featureString("barcodeScanner.codesDetected \(count)", "%lld is how many codes were found.")
        }
    }

    // MARK: Shared components

    package enum Component {

        package static var loading: LocalizedStringResource {
            featureString("component.loading", "Accessibility value on a button mid-request.")
        }

        package static var dismiss: LocalizedStringResource {
            featureString("component.dismiss", "VoiceOver action that takes an error banner away.")
        }

        /// How an error banner is announced: the word "Error" carries what the
        /// hidden triangle draws.
        ///
        /// - Parameter message: the already-localised sentence to announce.
        package static func spokenError(_ message: String) -> LocalizedStringResource {
            featureString("component.spokenError \(message)", "%@ is the error message being announced.")
        }
    }

    package enum Pagination {

        package static var loadingMore: LocalizedStringResource {
            featureString("pagination.loadingMore", "VoiceOver label for the spinner below the last row.")
        }

        package static var tryAgain: LocalizedStringResource {
            featureString("pagination.tryAgain", "Button that retries the page that failed.")
        }

        package static var noMoreItems: LocalizedStringResource {
            featureString("pagination.noMoreItems", "Shown once the collection is exhausted.")
        }
    }
}
