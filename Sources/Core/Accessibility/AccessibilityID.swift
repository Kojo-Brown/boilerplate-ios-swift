/// The accessibility identifiers the shipped screens publish, in one place.
///
/// Phase 12 item 4 is the first thing in this package that reads the published
/// accessibility tree rather than the source that produces it, and a UI test
/// can only find an element by something the element says about itself. There
/// were three candidates and only one of them is a name:
///
///   * **The label.** It is prose, it is localised, and it is the thing a
///     reader hears — so a test that queries by label fails the moment a
///     copy edit lands or the runner's language changes, and it fails as "the
///     button is not there" rather than as "the button is called something
///     else". `docs/localisation.md` is the whole of why that is not a
///     hypothetical here.
///   * **The position in the tree.** `app.buttons.element(boundBy: 2)` is a
///     query that keeps passing while pointing at a different control, which
///     is the failure mode worth the most effort to avoid.
///   * **The identifier.** Not localised, not rendered, not read out by
///     VoiceOver, and invisible in a snapshot — it exists for exactly this.
///
/// So every element a journey touches carries one, declared here and applied
/// in the view. Two properties keep that from rotting, and both are checked by
/// `Tools/assert-ui-test-journey.py` in the lint job, where they need no
/// toolchain:
///
///   * **Every identifier declared here is applied somewhere in `Sources/`.**
///     A constant no view carries is a query that can only ever fail, and a
///     `waitForExistence` against it is indistinguishable from a slow screen
///     until the timeout expires.
///   * **The copy the test bundle compiles says the same thing.** The UI test
///     target is an Xcode target rather than a SwiftPM one, so it cannot see
///     `package` declarations in this module; `UITestHost/UITests/Support/AccessibilityID.swift`
///     is its own copy, and the audit holds the two lists to being identical
///     name for name and value for value. A drifted copy would otherwise be a
///     suite that compiles, runs, and asserts against elements that no longer
///     exist.
///
/// The values are namespaced by screen and spelled in lower camel case after
/// the dot, which is the convention Xcode's own recorder emits.
package enum AccessibilityID {

    /// The sign-in screen. See `LoginView`.
    package enum Login {
        package static let emailField = "login.emailField"
        package static let passwordField = "login.passwordField"
        package static let signInButton = "login.signInButton"
        package static let errorBanner = "login.errorBanner"
    }

    /// The authenticated landing screen. See `HomeView`.
    ///
    /// `list` and `grid` are the two layouts `content` resolves between on the
    /// horizontal size class, and exactly one of them is in the tree at a
    /// time. That is what makes the simulator matrix worth running: the
    /// identifier is how a test on an iPad can assert it got the grid rather
    /// than a wider copy of the phone's list.
    package enum Home {
        package static let list = "home.list"
        package static let grid = "home.grid"
        package static let moreMenu = "home.moreMenu"
        package static let settingsMenuItem = "home.moreMenu.settings"
        package static let emptyState = "home.emptyState"
        package static let errorState = "home.errorState"
    }

    /// The pushed detail screen. See `ItemDetailView`.
    package enum ItemDetail {
        package static let titleRow = "itemDetail.titleRow"
        package static let identifierRow = "itemDetail.identifierRow"
    }

    /// The settings screen. See `SettingsView`.
    package enum Settings {
        package static let emailRow = "settings.emailRow"
        package static let nameField = "settings.nameField"
        package static let saveButton = "settings.saveButton"
        package static let signOutButton = "settings.signOutButton"
        package static let versionRow = "settings.versionRow"
    }
}
