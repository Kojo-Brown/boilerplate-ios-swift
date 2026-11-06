import XCTest

/// The steps more than one test needs before the thing it is actually about.
///
/// Phase 12 item 4. There is exactly one of these and it is sign-in, because
/// every screen past the login form is behind a session. It is a helper rather
/// than a `setUp` override for a reason worth keeping: `XCTestCase`'s lifecycle
/// methods are not main-actor isolated, XCUI is, and an override that declared
/// itself `@MainActor` would not compile against a non-isolated superclass
/// requirement. A function each test calls needs no override at all, and it
/// also means a test that wants to start signed *out* — `SignInJourneyTests`
/// does — simply does not call it.
enum UITestFlow {

    /// Launches the host, signs in, and returns the loaded Home screen.
    ///
    /// Fails the calling test, at the caller's line, if any step of that does
    /// not happen. It asserts rather than returning an optional because every
    /// caller's next line assumes a session: an optional would be unwrapped
    /// with a force or a `guard` in each of them, and the first is the same
    /// assertion spelled worse while the second reports as a skipped test.
    @MainActor
    static func signIn(
        email: String = "layout@example.invalid",
        password: String = "not-a-real-password",
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> HomeScreen {
        let app = UITestApplication.launch()
        let login = LoginScreen(app: app)
        let home = HomeScreen(app: app)

        login.awaitAppearance(file: file, line: line)
        login.signIn(email: email, password: password, file: file, line: line)
        home.awaitLoadedRows(file: file, line: line)
        return home
    }
}
