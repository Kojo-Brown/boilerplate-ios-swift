/// The test bundle's copy of the identifiers the app publishes.
///
/// Phase 12 item 4. This is a copy, and it is a copy on purpose rather than for
/// want of trying: `Sources/Core/Accessibility/AccessibilityID.swift` declares
/// the same names at `package` access, which reaches every target *in the
/// package* and this target is not one — it is an Xcode target in
/// `UITestHost/project.yml`. Raising the originals to `public` to share them
/// would widen the package's API surface for the benefit of a test, and
/// `import Core` from a UI test bundle links a second copy of the module into
/// the runner for the same reason.
///
/// What makes a copy safe is that it cannot drift. `Tools/assert-ui-test-journey.py`
/// parses both files and fails unless they declare the same names with the same
/// values, and separately fails on any identifier here that no view in
/// `Sources/` applies. Both directions matter, and the second one more: a query
/// for an identifier nothing carries does not fail fast. It waits out its
/// timeout and then reports that the screen does not have the element — which
/// reads exactly like a regression in the screen.
enum AccessibilityID {

    enum Login {
        static let emailField = "login.emailField"
        static let passwordField = "login.passwordField"
        static let signInButton = "login.signInButton"
        static let errorBanner = "login.errorBanner"
    }

    enum Home {
        static let list = "home.list"
        static let grid = "home.grid"
        static let moreMenu = "home.moreMenu"
        static let settingsMenuItem = "home.moreMenu.settings"
        static let emptyState = "home.emptyState"
        static let errorState = "home.errorState"
    }

    enum ItemDetail {
        static let titleRow = "itemDetail.titleRow"
        static let identifierRow = "itemDetail.identifierRow"
    }

    enum Settings {
        static let emailRow = "settings.emailRow"
        static let nameField = "settings.nameField"
        static let saveButton = "settings.saveButton"
        static let signOutButton = "settings.signOutButton"
        static let versionRow = "settings.versionRow"
    }
}
