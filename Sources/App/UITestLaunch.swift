import Core

/// The one switch a UI test throws, and everything that switch means.
///
/// Phase 12 item 4. An XCUITest drives the shipped app through its own
/// interface, which is the point of it and also the problem: the shipped app
/// talks to `https://api.example.com/v1`, writes a SwiftData store to disk, and
/// keeps a colour-scheme preference in `UserDefaults` that outlives the
/// process. A journey run against that is a journey whose verdict depends on a
/// network nobody controls and on what the *previous* run left behind — the
/// two properties that turn a suite into something people re-run until it goes
/// green.
///
/// So the host launches with ``argument`` and the composition root resolves
/// three things differently. Each of them is a substitution this package
/// already had; none of them is new code written for the test:
///
///   * **The dependency graph** becomes ``AppContainer/preview`` — every
///     collaborator its hand-written double, which is the substitution
///     `docs/dependency-injection.md` exists to make possible. `MockAuthService`
///     accepts any well-formed credentials after 100ms, `MockSyncStrategy`
///     answers with a fixed `mock@example.invalid`, and nothing reaches the
///     network.
///   * **The store** becomes `PersistenceController.makeInMemoryContainer()`,
///     built from the same schema and the same migration plan as the disk one,
///     so it is the app's container rather than a test's idea of one.
///   * **The preference** is cleared, below, because it is the only thing the
///     app persists outside that store.
///
/// What is deliberately *not* substituted is everything above the graph: the
/// `@main` entry point, the scene, `RootView`'s branch on the session, the
/// coordinator-backed `NavigationStack`, every view and every view model. That
/// is the part under test, and a seam that reached any further up would be a
/// suite exercising a second app.
///
/// ## Why the argument carries no leading dash
///
/// `UserDefaults` parses the process arguments as its highest-priority domain
/// and reads any `-key value` pair it finds there. A lone `-ui-testing` would
/// therefore make the *next* launch argument its value — or, as the last
/// argument, be swallowed silently — and a flag whose presence depends on its
/// position in a list is a flag that will one day be absent for no visible
/// reason. A bare token is never read as a key, so this one cannot be.
package enum UITestLaunch {

    /// The launch argument `UITestHost`'s XCUITest target passes.
    ///
    /// Spelled in the same string in `UITestHost/UITests/Support/UITestApplication.swift`.
    /// `Tools/assert-ui-test-journey.py` holds the two to being equal, because
    /// a typo on either side is not a failure: it is a suite that drives the
    /// *live* graph, reaches a network it cannot have, and reports as a flake.
    package static let argument = "UI_TESTING"

    /// Whether this process was launched by the UI test suite.
    ///
    /// Read once, at the top of `BoilerplateApp.init()`, rather than wherever a
    /// decision needs it: a graph that is live in one place and doubled in
    /// another is the one outcome worse than either.
    package static var isActive: Bool {
        CommandLine.arguments.contains(argument)
    }

    /// Clears what the app persists outside its SwiftData store.
    ///
    /// Only the colour-scheme preference, today: `AppState` is its one writer,
    /// and the failure ledger that would otherwise be the second is not in the
    /// doubled graph. The removal itself is `AppState`'s, because the key is —
    /// see `AppState.forgetPersistedPreferences()`.
    package static func resetPersistentState() {
        AppState.forgetPersistedPreferences()
    }
}
