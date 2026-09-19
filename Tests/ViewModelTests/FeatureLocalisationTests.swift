import Foundation
import Testing
@testable import Core
@testable import Features

// MARK: - Features

@Suite("Features' String Catalog")
struct FeatureLocalisationTests {

    static let everyString: [(LocalizedStringResource, String)] = [
        (FeatureStrings.Home.title, "home.title"),
        (FeatureStrings.Home.searchPrompt, "home.searchPrompt"),
        (FeatureStrings.Home.refreshing, "home.refreshing"),
        (FeatureStrings.Home.scanText, "home.menu.scanText"),
        (FeatureStrings.Home.scanBarcode, "home.menu.scanBarcode"),
        (FeatureStrings.Home.settings, "home.menu.settings"),
        (FeatureStrings.Home.moreOptions, "home.menu.more"),
        (FeatureStrings.Home.loading, "home.loading"),
        (FeatureStrings.Home.openItemHint, "home.item.openHint"),
        (FeatureStrings.Home.errorTitle, "home.error.title"),
        (FeatureStrings.Home.retry, "home.error.retry"),
        (FeatureStrings.Home.emptyTitle, "home.empty.title"),
        (FeatureStrings.Home.emptyDescription, "home.empty.description"),
        (FeatureStrings.ItemDetail.section, "itemDetail.section"),
        (FeatureStrings.ItemDetail.title, "itemDetail.title"),
        (FeatureStrings.ItemDetail.identifier, "itemDetail.id"),
        (FeatureStrings.Login.signIn, "login.signIn"),
        (FeatureStrings.Login.heading, "login.heading"),
        (FeatureStrings.Login.email, "login.email"),
        (FeatureStrings.Login.passwordPlaceholder, "login.passwordPlaceholder"),
        (FeatureStrings.Login.password, "login.password"),
        (FeatureStrings.Login.passwordHint, "login.passwordHint"),
        (FeatureStrings.Login.signingIn, "login.signingIn"),
        (FeatureStrings.Login.dividerOr, "login.dividerOr"),
        (FeatureStrings.Login.dividerLabel, "login.dividerLabel"),
        (FeatureStrings.Biometric.reason, "biometric.reason"),
        (FeatureStrings.Biometric.faceID, "biometric.faceID"),
        (FeatureStrings.Biometric.touchID, "biometric.touchID"),
        (FeatureStrings.Biometric.unavailable, "biometric.unavailable"),
        (FeatureStrings.Biometric.authenticating, "biometric.authenticating"),
        (FeatureStrings.Settings.title, "settings.title"),
        (FeatureStrings.Settings.accountSection, "settings.section.account"),
        (FeatureStrings.Settings.appearanceSection, "settings.section.appearance"),
        (FeatureStrings.Settings.appSection, "settings.section.app"),
        (FeatureStrings.Settings.signOut, "settings.signOut"),
        (FeatureStrings.Settings.version, "settings.version"),
        (FeatureStrings.Settings.build, "settings.build"),
        (FeatureStrings.Settings.email, "settings.email"),
        (FeatureStrings.Settings.name, "settings.name"),
        (FeatureStrings.Settings.save, "settings.save"),
        (FeatureStrings.Settings.saving, "settings.saving"),
        (FeatureStrings.Settings.loadingProfile, "settings.loadingProfile"),
        (FeatureStrings.Settings.loadingProfileLabel, "settings.loadingProfileLabel"),
        (FeatureStrings.Settings.offlineCopy, "settings.offlineCopy"),
        (FeatureStrings.Settings.appearanceFooter(.system), "settings.appearance.footer.system"),
        (FeatureStrings.Settings.appearanceFooter(.light), "settings.appearance.footer.light"),
        (FeatureStrings.Settings.appearanceFooter(.dark), "settings.appearance.footer.dark"),
        (FeatureStrings.CameraPermission.title, "camera.permission.title"),
        (FeatureStrings.CameraPermission.body, "camera.permission.body"),
        (FeatureStrings.CameraPermission.openSettings, "camera.permission.openSettings"),
        (FeatureStrings.Scanner.copy, "scanner.copy"),
        (FeatureStrings.Scanner.copied, "scanner.copied"),
        (FeatureStrings.Scanner.clearText, "scanner.clearText"),
        (FeatureStrings.Scanner.clearCodes, "scanner.clearCodes"),
        (FeatureStrings.Scanner.pause, "scanner.pause"),
        (FeatureStrings.Scanner.start, "scanner.start"),
        (FeatureStrings.TextScanner.title, "textScanner.title"),
        (FeatureStrings.TextScanner.rotorName, "textScanner.rotor.textBlocks"),
        (FeatureStrings.TextScanner.blocksDetected(3), "textScanner.blocksDetected %lld"),
        (FeatureStrings.BarcodeScanner.title, "barcodeScanner.title"),
        (FeatureStrings.BarcodeScanner.codesDetected(3), "barcodeScanner.codesDetected %lld"),
        (FeatureStrings.Component.loading, "component.loading"),
        (FeatureStrings.Component.dismiss, "component.dismiss"),
        (FeatureStrings.Component.spokenError("Boom"), "component.spokenError %@"),
        (FeatureStrings.Pagination.loadingMore, "pagination.loadingMore"),
        (FeatureStrings.Pagination.tryAgain, "pagination.tryAgain"),
        (FeatureStrings.Pagination.noMoreItems, "pagination.noMoreItems"),
        (FeatureStrings.AuthError.invalidCredentials, "error.auth.invalidCredentials"),
        (FeatureStrings.AuthError.networkUnavailable, "error.auth.networkUnavailable"),
        (FeatureStrings.SocialError.invalidCredential, "error.social.invalidCredential"),
        (FeatureStrings.SocialError.userCancelled, "error.social.userCancelled"),
        (FeatureStrings.SocialError.notConfigured, "error.social.notConfigured"),
        (FeatureStrings.SocialError.tokenExchangeFailed, "error.social.tokenExchangeFailed"),
        (FeatureStrings.CameraError.notAuthorized, "error.camera.notAuthorized"),
        (FeatureStrings.CameraError.deviceUnavailable, "error.camera.deviceUnavailable"),
        (FeatureStrings.CameraError.configurationFailed, "error.camera.configurationFailed"),
        (FeatureStrings.RecognitionError.noResult, "error.textRecognition.noResult"),
        (
            FeatureStrings.RecognitionError.processingFailed("Vision said no"),
            "error.textRecognition.processingFailed %@"
        ),
        (FeatureStrings.BarcodeError.processingFailed("Vision said no"), "error.barcode.processingFailed %@"),
    ]

    /// A loop rather than `@Test(arguments:)` — see
    /// ``CoreLocalisationTests/everyCoreStringResolves()``.
    @Test("Every string Features declares resolves out of its own catalog")
    func everyFeatureStringResolves() {
        for (resource, key) in Self.everyString {
            expectResolves(resource, key: key)
        }
    }

    @Test("The feature errors describe themselves from the catalog")
    func featureErrorDescriptionsResolve() {
        let invalid = AuthError.invalidCredentials
        #expect(invalid.localizedDescription == FeatureStrings.AuthError.invalidCredentials.string)
        #expect(!invalid.localizedDescription.contains("error.auth"))
        #expect(CameraError.notAuthorized.localizedDescription == FeatureStrings.CameraError.notAuthorized.string)
        #expect(TextRecognitionError.processingFailed("Vision said no").localizedDescription.contains("Vision said no"))
    }

    /// The design-system components take a resource rather than a `String`, so
    /// a shipped call site has to hand them something that came out of a
    /// catalog. The type is `ExpressibleByStringLiteral`, so a literal still
    /// compiles — and resolves to itself, which is what the previews rely on
    /// and what `Tools/assert-localisation.py` refuses outside them.
    @Test("A design-system component carries a resource, not a resolved string")
    @MainActor
    func componentsTakeResources() {
        let button = AppButton(FeatureStrings.Login.signIn, asyncAction: {})
        #expect(button.label.string == FeatureStrings.Login.signIn.string)
        #expect(button.label.string != "login.signIn")

        let literal = AppButton("Sign In", asyncAction: {})
        #expect(literal.label.string == "Sign In")
    }
}

// MARK: - Plurals

/// The three counted strings, and the rule that they are counted *in the
/// catalog*.
///
/// Two of these were `"\(count) block\(count == 1 ? "" : "s") detected"` —
/// English's plural rule, written in Swift, in a view. English is the language
/// with the fewest categories to get wrong: Russian needs three forms and picks
/// between them on the last two digits, Arabic needs six and has a form for
/// exactly two, Japanese needs one. No ternary reaches any of that.
///
/// The second cost is quieter and is why these cannot simply be left: a
/// sentence assembled at runtime out of fragments is a sentence no translator
/// ever sees. There is no string to send them — only "block", "s" and
/// "detected", in an order the catalog cannot express.
///
/// These assertions are in English because English is the catalog's only
/// language. What they establish is that the plural *machinery* is wired up —
/// that the key carries its format specifier, that the catalog's
/// `variations.plural` block survived compilation into a `.stringsdict`, and
/// that the selection happens on the count. Adding a language is then a catalog
/// edit with no code change, which is the property being bought.
@Suite("Pluralisation happens in the catalog")
struct PluralisationTests {

    @Test(
        "The recognised-block heading selects its form on the count",
        arguments: [(0, "blocks"), (1, "block"), (2, "blocks"), (11, "blocks"), (21, "blocks")]
    )
    func blockCountPluralises(count: Int, expected: String) {
        let resolved = FeatureStrings.TextScanner.blocksDetected(count).string

        #expect(resolved.contains("\(count)"))
        #expect(resolved.contains(" \(expected) "))
    }

    /// One form is singular and the rest are not, which is the whole of
    /// English's rule — including zero, which English pluralises and several
    /// other languages do not.
    @Test("Exactly one English form is singular")
    func onlyOneIsSingular() {
        let singulars = (0...20).filter { count in
            FeatureStrings.TextScanner.blocksDetected(count).string.contains(" block ")
        }

        #expect(singulars == [1])
    }

    @Test(
        "The barcode heading pluralises on the same rule",
        arguments: [(1, "code"), (2, "codes"), (0, "codes")]
    )
    func codeCountPluralises(count: Int, expected: String) {
        #expect(FeatureStrings.BarcodeScanner.codesDetected(count).string.contains(" \(expected) "))
    }

    /// The pagination limit is the plural that is not on a screen: it is inside
    /// an error, reached through `localizedDescription`, and the form still has
    /// to be chosen.
    @Test("A counted error picks its form through localizedDescription")
    func paginationLimitPluralises() {
        #expect(PaginationError.tooManyEmptyPages(limit: 1).localizedDescription.contains("empty page "))
        #expect(PaginationError.tooManyEmptyPages(limit: 4).localizedDescription.contains("empty pages "))
    }
}
