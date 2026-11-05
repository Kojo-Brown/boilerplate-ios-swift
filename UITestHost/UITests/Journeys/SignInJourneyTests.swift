import XCTest

/// The journey: signed out to signed out, through everything in between.
///
/// Phase 12 item 4, and the first test in this repository that exercises the
/// app as an app. Everything the package's own suite can reach it reaches
/// directly — a view model is constructed, an action is sent, a published
/// property is read — and the three things it has never been able to touch are
/// exactly the three this file is about:
///
///   1. **That the composition root composes.** `BoilerplateApp.init()` opens a
///      `ModelContainer`, builds the graph, subscribes `SessionObserver` and
///      `MetricKitDiagnosticSubscriber`, and registers a background task whose
///      identifier has to be in the host's `Info.plist`. Every one of those can
///      fail at launch, none of them is reachable from a unit test, and the
///      package compiled and passed for twelve phases without any of them ever
///      having run.
///   2. **That `SessionObserver` closes the loop.** Signing in publishes a
///      `UserSignedIn`; something has to receive it, write `AppState`, and make
///      `RootView` swap its whole subtree. `EventBusTests` asserts the
///      broadcast and `SessionObserverTests` asserts the handler; neither can
///      assert that the screen changed.
///   3. **That the accessibility tree is actually published.**
///      `Tools/assert-accessibility-audit.py` says in its own docstring that it
///      checks the *shape* of three defects in the source because
///      `_UIHostingView` vends no elements in a unit-test process, and that
///      reading the real tree "needs an XCUITest target with a host app, which
///      this package does not have". It does now. Every query below is a read
///      of the published tree, and a control missing from it fails here.
///
/// ## Why it is one test and eight methods
///
/// One test, because each step is the precondition of the next: there is no
/// Settings screen to open without a session, so eight tests would be eight
/// sign-ins and the same sequence run eight times. Eight methods, because a
/// single eighty-line body is a failure reported as a line number — and
/// `XCTContext.runActivity` is what turns it into a sentence instead, so the
/// report names "Open Settings from the Home toolbar" and the method it names
/// is the one to read.
final class SignInJourneyTests: XCTestCase {

    /// Credentials that are obviously not credentials.
    ///
    /// `MockAuthService` accepts anything `LoginViewModel.isFormValid` lets
    /// through — an `@` and eight characters — so these are shaped to pass that
    /// and to be unmistakable in a log.
    private static let email = "qa.journey@example.invalid"
    private static let password = "not-a-real-password"

    /// What the doubled graph answers a profile read with.
    /// `MockSyncStrategy.stubbedUser`.
    private static let profileEmail = "mock@example.invalid"

    /// `MARKETING_VERSION` in `UITestHost/project.yml`.
    private static let hostVersion = "1.0.0"

    /// The row the journey opens, and the term that isolates it.
    ///
    /// `HomeViewModel.catalogue` mints "Item 1" through "Item 10", and this is
    /// deliberately the *last* of them, because reaching it is the only
    /// viewport-independent evidence that the whole corpus arrived — see
    /// ``searchDownToOneRow(_:)``. "Item 10" also happens to be the one term in
    /// the ten that cannot match another row: "Item 1" is a prefix of it, not
    /// the reverse.
    private static let openedRow = "Item 10"

    @MainActor
    func testSignedOutUserCanSignInBrowseAnItemAndSignOut() {
        continueAfterFailure = false
        let app = UITestApplication.launch()

        assertLaunchesSignedOut(app)
        signIn(app)
        searchDownToOneRow(app)
        pushAndPopTheItemDetail(app)
        openSettings(app)
        assertProfileAndHostVersion(app)
        renameTheProfile(app)
        signOutAndLandBackOnLogin(app)
    }

    /// The other direction: a form the view model refuses.
    ///
    /// Its own test rather than a step in the journey, because it asserts that
    /// nothing happens — and a step asserting nothing happened, run between two
    /// steps that each made something happen, is a step that passes when the
    /// screen has moved on for an unrelated reason.
    @MainActor
    func testSignInIsRefusedForAnIncompleteForm() {
        continueAfterFailure = false

        let app = UITestApplication.launch()
        let login = LoginScreen(app: app)
        let home = HomeScreen(app: app)

        login.awaitAppearance()
        login.emailField.replaceText(with: Self.email)
        // Seven characters. `LoginViewModel.isFormValid` wants eight.
        login.passwordField.replaceText(with: "7-chars")

        XCTAssertFalse(
            login.signInButton.isEnabled,
            "A password under eight characters must leave the Sign In button disabled."
        )
        XCTAssertFalse(home.list.exists || home.grid.exists, "No session, so no Home.")
    }

    // MARK: - The steps

    @MainActor
    private func assertLaunchesSignedOut(_ app: XCUIApplication) {
        XCTContext.runActivity(named: "The app launches signed out") { _ in
            LoginScreen(app: app).awaitAppearance()
            let home = HomeScreen(app: app)
            XCTAssertFalse(
                home.list.exists || home.grid.exists,
                "A launch with no session must not reach Home."
            )
        }
    }

    @MainActor
    private func signIn(_ app: XCUIApplication) {
        XCTContext.runActivity(named: "Sign in with an email and a password") { _ in
            let login = LoginScreen(app: app)
            let home = HomeScreen(app: app)
            login.signIn(email: Self.email, password: Self.password)
            // The session is what swaps `RootView`'s subtree, so the rows
            // arriving is the assertion that the event reached the observer.
            home.awaitLoadedRows()
            login.signInButton.awaitDisappearance("the sign-in screen")
            // The authenticated layout is in the tree, which is the other half
            // of the swap: the rows could in principle arrive under the login
            // branch, and this is what says they did not.
            //
            // What used to be here was `home.row(titled: "Item 10").exists`,
            // asserting "the stub fetch returns ten rows" — and it failed on
            // the first run of this suite for a reason worth keeping written
            // down. A `List` is lazy: it materialises the rows it can show, so
            // the tenth of ten is not in the accessibility tree on an iPhone 16
            // and is on an iPad. An existence check against it is a claim about
            // the viewport wearing the words of a claim about the data, which
            // is the exact mistake `AccessibilityID` argues against in its
            // other form. The corpus is asserted in the next step instead,
            // where the search brings the tenth row on screen itself.
            XCTAssertTrue(
                home.list.exists || home.grid.exists,
                "Signing in must put one of HomeView's two layouts in the tree."
            )
        }
    }

    /// Two things at once, and the second is why the term is the last row.
    ///
    /// The search filters, which is what the step is named for. It also brings
    /// "Item 10" on screen, and *that* is the assertion that the stub fetch
    /// returned the whole catalogue rather than a prefix of it: the row cannot
    /// be matched by a filter unless it is in the corpus, and once matched it
    /// is the only row there is, so no amount of lazy rendering can hide it.
    /// A device-independent claim about the data, made through the one lens
    /// that does not depend on how many rows happen to fit.
    @MainActor
    private func searchDownToOneRow(_ app: XCUIApplication) {
        XCTContext.runActivity(named: "Search the list down to one row") { _ in
            let home = HomeScreen(app: app)
            home.search(for: Self.openedRow)
            home.row(titled: Self.openedRow)
                .awaitExistence("the tenth row, which only the fetched corpus can supply")
            home.row(titled: "Item 1").awaitDisappearance("a non-matching row")
        }
    }

    @MainActor
    private func pushAndPopTheItemDetail(_ app: XCUIApplication) {
        XCTContext.runActivity(named: "Push the item detail and come back") { _ in
            let home = HomeScreen(app: app)
            let detail = ItemDetailScreen(app: app)

            home.row(titled: Self.openedRow).tap()
            detail.awaitAppearance()
            XCTAssertTrue(
                readableText(of: detail.titleRow).contains(Self.openedRow),
                "The detail screen shows the row that was tapped: \(readableText(of: detail.titleRow))"
            )
            XCTAssertFalse(
                readableText(of: detail.identifierRow).isEmpty,
                "The detail screen shows the item's identifier."
            )

            NavigationBarScreen(app: app).goBack()
            // The search term survives the pop, because the view model is
            // `@State` on a screen the stack kept. A list back at ten rows here
            // would mean `HomeView` had been rebuilt from scratch.
            home.row(titled: Self.openedRow).awaitExistence("the searched row after the pop")
            XCTAssertFalse(home.row(titled: "Item 1").exists, "The search term survived the pop.")
        }
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        XCTContext.runActivity(named: "Open Settings from the Home toolbar") { _ in
            HomeScreen(app: app).openSettings()
            SettingsScreen(app: app).awaitAppearance()
        }
    }

    @MainActor
    private func assertProfileAndHostVersion(_ app: XCUIApplication) {
        XCTContext.runActivity(named: "The profile comes from the sync strategy") { _ in
            let settings = SettingsScreen(app: app)
            settings.emailRow.awaitExistence("the account email row")
            XCTAssertTrue(
                readableText(of: settings.emailRow).contains(Self.profileEmail),
                """
                The email shown is the profile the strategy resolved, not the one typed into the \
                login form: \(readableText(of: settings.emailRow))
                """
            )
            // `Bundle.main.appVersion` reads `CFBundleShortVersionString` and
            // falls back to an em dash. This is the one assertion holding
            // `UITestHost/Host/Info.plist` to being a real app's plist rather
            // than the minimum that launches.
            XCTAssertTrue(
                readableText(of: settings.versionRow).contains(Self.hostVersion),
                "Expected the host's marketing version: \(readableText(of: settings.versionRow))"
            )
        }
    }

    @MainActor
    private func renameTheProfile(_ app: XCUIApplication) {
        XCTContext.runActivity(named: "Rename the profile and save it") { _ in
            let settings = SettingsScreen(app: app)
            settings.rename(to: "Journey Tester")
            XCTAssertEqual(
                settings.nameField.value as? String,
                "Journey Tester",
                "The field holds what the store reduced, which is what `Store.binding` exists to keep."
            )
        }
    }

    @MainActor
    private func signOutAndLandBackOnLogin(_ app: XCUIApplication) {
        XCTContext.runActivity(named: "Sign out, and land back on the login screen") { _ in
            let login = LoginScreen(app: app)
            let home = HomeScreen(app: app)
            SettingsScreen(app: app).signOut()
            // Back to `RootView`'s other branch: the whole authenticated
            // subtree goes, which is the second half of what `SessionObserver`
            // does and the half no unit test can see.
            login.signInButton.awaitExistence("the sign-in screen after signing out")
            XCTAssertFalse(
                home.list.exists || home.grid.exists,
                "Signing out must take the authenticated subtree with it."
            )
        }
    }
}
