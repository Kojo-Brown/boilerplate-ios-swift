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

    /// The button the engaged search field puts in the bar beside itself.
    ///
    /// Positional, like ``NavigationBarScreen/goBack(file:line:)`` and for the
    /// same reason: `.searchable` builds it, so there is nothing in `HomeView`
    /// to hang an identifier on, and its only name is the localised "Cancel".
    ///
    /// `children(matching:)` rather than `buttons[…]` is the load-bearing part.
    /// A descendant query matches the field's own clear button too — the bar
    /// publishes `SearchField → Button "Clear text"` as well as its own
    /// `Button "Cancel"` — and clearing the text leaves the field engaged,
    /// which is the state this is here to leave. Direct children of the bar are
    /// the bar's own buttons, and while the search presentation holds it there
    /// is exactly one.
    var searchCancelButton: XCUIElement {
        app.navigationBars.firstMatch.children(matching: .button).firstMatch
    }

    /// Leaves the search presentation, so the bar carries the toolbar again.
    ///
    /// A precondition of ``openSettings(file:line:)`` rather than a tidy-up,
    /// and the reason is the one thing every leg of the three runs that
    /// reached this step established: an
    /// engaged `.searchable` field **replaces the navigation bar's contents**
    /// on a compact width. The toolbar item is not hidden, not renamed and not
    /// missing its identifier — it is not in the tree at all, and no query for
    /// it can succeed until the search is dismissed. A journey that searches
    /// and then reaches for the toolbar is asking the bar for something it is
    /// not currently showing.
    ///
    /// Returning early when the menu is already there is what makes this work
    /// across the matrix rather than on the phones: a regular width can seat
    /// the field in the bar without taking it over, and then there is no Cancel
    /// button to tap and nothing to leave.
    func dismissSearch(file: StaticString = #filePath, line: UInt = #line) {
        guard !moreMenu.exists else { return }

        let cancel = searchCancelButton
        guard cancel.waitForExistence(timeout: UITestTimeout.transition) else {
            XCTFail(
                """
                The Home bar is showing neither the toolbar menu \
                ("\(AccessibilityID.Home.moreMenu)") nor a button to leave the search by, \
                so it is in neither of the two states this step knows how to be in. What \
                the bar published is below.

                Navigation bar:
                \(app.navigationBars.firstMatch.debugDescription)
                """,
                file: file,
                line: line
            )
            return
        }
        cancel.tap()
    }

    /// Opens the toolbar menu and picks Settings, and says what the bar held
    /// if it cannot.
    ///
    /// Call ``dismissSearch(file:line:)`` first if anything has typed into the
    /// search field. That is not a courtesy — an engaged field replaces the
    /// bar's contents, so this query cannot match while one is open, and it is
    /// what every red leg of this suite so far was actually failing on.
    ///
    /// The dump is here because of what those runs cost to read. The failure
    /// said only that there were no matches for `home.moreMenu` — true, and
    /// identical to what a renamed identifier, a menu that never rendered, a
    /// screen that never appeared, a modifier that did not propagate *and* a
    /// bar showing something else entirely would each have said. XCUITest
    /// truncates the element list it prints with that message, so the one thing
    /// worth knowing — what the bar *does* publish — was not in the log at all,
    /// and the answer was the fifth of those five and cost two rounds of CI and
    /// a wrong fix to the app.
    ///
    /// A navigation bar is a handful of elements, so printing its subtree costs
    /// a few lines and only on the way to a failure. It belongs here rather than
    /// in the journey because this is where the query lives.
    func openSettings(file: StaticString = #filePath, line: UInt = #line) {
        if !moreMenu.waitForExistence(timeout: UITestTimeout.transition) {
            XCTFail(
                """
                The Home toolbar menu is not in the published tree under \
                "\(AccessibilityID.Home.moreMenu)". Two causes are known and the bar's own \
                subtree tells them apart: an engaged search field replaces the bar's \
                contents, in which case the dump below is a search field and a Cancel \
                button and the missing step is `dismissSearch()`; or the bar is showing its \
                toolbar and the `Menu`'s identifier did not survive the bridge to \
                `UIBarButtonItem`, in which case the dump holds a button with the \
                "More options" label and no identifier, and the fallback is a structural \
                query as `NavigationBarScreen.goBack` already uses.

                Navigation bar:
                \(app.navigationBars.firstMatch.debugDescription)
                """,
                file: file,
                line: line
            )
            return
        }
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
