import XCTest

/// What each screen offers a test, in the screen's own words.
///
/// Phase 12 item 4. The alternative — `app.buttons["login.signInButton"].tap()`
/// written out in every test — is the arrangement where a renamed identifier is
/// a search-and-replace across the suite and a changed flow is a rewrite of
/// it. Here a journey reads as the sequence of things a person does, and the
/// query behind each one is in exactly one place.
///
/// Every type below is a `struct` over an `XCUIApplication`: there is no state
/// to hold, because the state is on the simulator. They are `@MainActor`
/// because XCUI is.
///
/// What is *not* here is any assertion about the screen being correct. A page
/// object says how to find things and how to act; whether what it found is
/// right is the test's sentence to write, and a helper that asserted on the
/// way past would hide which step failed.
@MainActor
struct LoginScreen {

    let app: XCUIApplication

    var emailField: XCUIElement { app.textFields[AccessibilityID.Login.emailField] }
    var passwordField: XCUIElement { app.secureTextFields[AccessibilityID.Login.passwordField] }
    var signInButton: XCUIElement { app.buttons[AccessibilityID.Login.signInButton] }
    var errorBanner: XCUIElement { app.element(withIdentifier: AccessibilityID.Login.errorBanner) }

    /// Waits for the screen the app launches on.
    @discardableResult
    func awaitAppearance(file: StaticString = #filePath, line: UInt = #line) -> LoginScreen {
        signInButton.awaitExistence("the sign-in screen", timeout: UITestTimeout.launch, file: file, line: line)
        return self
    }

    /// Fills the form and submits it.
    ///
    /// `LoginViewModel.isFormValid` wants an `@` and eight characters, so a
    /// caller passing less is testing the disabled button rather than the
    /// journey — which is `testSignInRejectsAnIncompleteForm`.
    func signIn(email: String, password: String, file: StaticString = #filePath, line: UInt = #line) {
        emailField.replaceText(with: email, file: file, line: line)
        passwordField.replaceText(with: password, file: file, line: line)
        signInButton.awaitExistence("the Sign In button", file: file, line: line)
        signInButton.tap()
    }
}

/// The authenticated landing screen.
@MainActor
struct HomeScreen {

    let app: XCUIApplication

    /// The layout `HomeView.content` resolved to, which is the list on a
    /// compact horizontal size class and the grid on a regular one.
    var list: XCUIElement { app.element(withIdentifier: AccessibilityID.Home.list) }
    var grid: XCUIElement { app.element(withIdentifier: AccessibilityID.Home.grid) }

    /// The field `.searchable` publishes.
    ///
    /// Queried by type rather than by identifier: the modifier builds the field
    /// itself and there is nothing in `HomeView` to hang an identifier on. Its
    /// one name is the localised prompt, which is the thing not to query by.
    var searchField: XCUIElement { app.searchFields.firstMatch }

    var moreMenu: XCUIElement { app.buttons[AccessibilityID.Home.moreMenu] }
    var settingsMenuItem: XCUIElement { app.buttons[AccessibilityID.Home.settingsMenuItem] }

    /// A row, by the title `HomeView` publishes as its accessibility label.
    ///
    /// The one query in this bundle that goes by label, because the row's name
    /// *is* its data — `HomeViewModel.catalogue` mints "Item 1" through "Item
    /// 10" — rather than prose from a catalogue. An identifier per row would
    /// have to encode the same string to be useful.
    func row(titled title: String) -> XCUIElement { app.buttons[title] }

    /// Waits for the first fetch to land. `HomeViewModel`'s stub sleeps 600ms.
    @discardableResult
    func awaitLoadedRows(file: StaticString = #filePath, line: UInt = #line) -> HomeScreen {
        row(titled: "Item 1").awaitExistence("the first Home row", file: file, line: line)
        return self
    }

    func search(for query: String, file: StaticString = #filePath, line: UInt = #line) {
        searchField.awaitExistence("the search field", file: file, line: line)
        searchField.tap()
        searchField.typeText(query)
    }

    func openSettings(file: StaticString = #filePath, line: UInt = #line) {
        moreMenu.awaitExistence("the toolbar menu", file: file, line: line)
        moreMenu.tap()
        settingsMenuItem.awaitExistence("the Settings menu item", file: file, line: line)
        settingsMenuItem.tap()
    }
}

/// The pushed detail screen.
@MainActor
struct ItemDetailScreen {

    let app: XCUIApplication

    var titleRow: XCUIElement { app.element(withIdentifier: AccessibilityID.ItemDetail.titleRow) }
    var identifierRow: XCUIElement { app.element(withIdentifier: AccessibilityID.ItemDetail.identifierRow) }

    @discardableResult
    func awaitAppearance(file: StaticString = #filePath, line: UInt = #line) -> ItemDetailScreen {
        titleRow.awaitExistence("the item detail screen", file: file, line: line)
        return self
    }
}

/// The settings screen.
@MainActor
struct SettingsScreen {

    let app: XCUIApplication

    var emailRow: XCUIElement { app.element(withIdentifier: AccessibilityID.Settings.emailRow) }
    var versionRow: XCUIElement { app.element(withIdentifier: AccessibilityID.Settings.versionRow) }
    var nameField: XCUIElement { app.textFields[AccessibilityID.Settings.nameField] }
    var saveButton: XCUIElement { app.buttons[AccessibilityID.Settings.saveButton] }
    var signOutButton: XCUIElement { app.buttons[AccessibilityID.Settings.signOutButton] }

    @discardableResult
    func awaitAppearance(file: StaticString = #filePath, line: UInt = #line) -> SettingsScreen {
        signOutButton.awaitExistence("the settings screen", file: file, line: line)
        return self
    }

    func rename(to name: String, file: StaticString = #filePath, line: UInt = #line) {
        nameField.replaceText(with: name, file: file, line: line)
        saveButton.awaitExistence("the Save button", file: file, line: line)
        saveButton.tap()
    }

    func signOut(file: StaticString = #filePath, line: UInt = #line) {
        signOutButton.awaitExistence("the Sign Out button", file: file, line: line)
        signOutButton.tap()
    }
}

/// Navigation that belongs to the bar rather than to any one screen.
@MainActor
struct NavigationBarScreen {

    let app: XCUIApplication

    /// The leading button of the top navigation bar.
    ///
    /// Positional, and it is the one query in this bundle that is — which is
    /// worth saying plainly, because `AccessibilityID` argues against exactly
    /// this. The back button is built by `NavigationStack`, not by any view in
    /// `Sources/`, so there is nowhere to apply an identifier; its only name is
    /// the previous screen's localised title, which is worse. First-of-the-bar
    /// is stable for a stack that pushes one screen at a time, and the
    /// alternative — a swipe from the edge — is a gesture that silently does
    /// nothing when it misses.
    func goBack(file: StaticString = #filePath, line: UInt = #line) {
        let back = app.navigationBars.firstMatch.buttons.firstMatch
        back.awaitExistence("the back button", file: file, line: line)
        back.tap()
    }
}

/// The label and value of an element, joined.
///
/// SwiftUI's `LabeledContent` publishes "Email" as the name and the address as
/// the value on one OS version, and both as one name on another. A test that
/// read only `value` would pass on the first and fail on the second for no
/// reason a reader could act on, which is precisely the kind of difference a
/// simulator matrix exists to find and not the kind worth failing over.
@MainActor
func readableText(of element: XCUIElement) -> String {
    let value = element.value as? String
    return [element.label, value].compactMap { $0 }.joined(separator: " ")
}
