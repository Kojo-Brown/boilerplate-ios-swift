import XCTest

/// How every test in this bundle launches the host, and the waits it is allowed
/// to use.
///
/// Phase 12 item 4. Two decisions live here rather than in each test:
///
///   * **The launch argument.** `UITestLaunch.argument` in the app is the other
///     half of ``launchArgument``, and
///     `Tools/assert-ui-test-journey.py` holds the two strings equal. A
///     mismatch is not a compile error and not a test failure either: the app
///     launches with the *live* dependency graph, the journey reaches for
///     `https://api.example.com/v1`, and the suite reports as a network flake
///     for as long as it takes somebody to read the two files side by side.
///   * **The timeouts.** Named, few, and justified below. A test that invents
///     its own is a test whose author was tuning a number until it passed,
///     which is how a suite ends up with a 60-second wait nobody can remove.
///
/// There is deliberately no `sleep` anywhere in this bundle, and the audit
/// fails on one. Every wait is a `waitForExistence` against the thing the
/// previous step was supposed to produce, so a broken step fails as "the Home
/// list never appeared" rather than as a later assertion against a screen that
/// was not ready.
enum UITestApplication {

    /// The argument the host reads in `BoilerplateApp.init()`.
    ///
    /// No leading dash, which is load-bearing — see `UITestLaunch`.
    static let launchArgument = "UI_TESTING"

    /// A freshly launched host, in its doubled graph, signed out.
    @MainActor
    static func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [launchArgument]
        app.launch()
        return app
    }
}

/// The waits this bundle uses, each one named after what it is waiting for.
enum UITestTimeout {

    /// A screen appearing after a launch, which includes the simulator's own
    /// first-launch work: the process spawn, the SwiftData container opening
    /// and the first frame. Generous because it is paid once per test and a
    /// cold runner is slower than a warm one by more than any other step here.
    static let launch: TimeInterval = 30

    /// A transition inside a running app: a push, a pop, a sheet, a menu
    /// opening, a list reloading. `MockAuthService` answers in 100ms and
    /// `HomeViewModel`'s stub fetch in 600ms, so this is roughly an order of
    /// magnitude of headroom over the slowest thing being waited for.
    static let transition: TimeInterval = 10

    /// An element expected *not* to be there, after something that should have
    /// removed it. Short on purpose: the assertion is that it is already gone,
    /// so the only thing a long wait buys is a long wait.
    static let disappearance: TimeInterval = 5
}

extension XCUIElement {

    /// Fails the calling test, by name and line, if this element does not
    /// appear within `timeout`.
    ///
    /// `#filePath`/`#line` defaults are what make a failure point at the step
    /// in the journey rather than at this file — without them every timeout in
    /// the suite reports against the same line of the same helper.
    @MainActor
    @discardableResult
    func awaitExistence(
        _ describing: String,
        timeout: TimeInterval = UITestTimeout.transition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        XCTAssertTrue(
            waitForExistence(timeout: timeout),
            "Timed out after \(timeout)s waiting for \(describing) (identifier: \(identifier)).",
            file: file,
            line: line
        )
        return self
    }

    /// Fails the calling test if this element is still there after `timeout`.
    @MainActor
    func awaitDisappearance(
        _ describing: String,
        timeout: TimeInterval = UITestTimeout.disappearance,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: self
        )
        let result = XCTWaiter.wait(for: [gone], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "\(describing) was still present after \(timeout)s.",
            file: file,
            line: line
        )
    }

    /// Clears the field and types `text` into it, then asserts the field
    /// actually took it.
    ///
    /// The assertion is the point. `typeText` reports no error when the field
    /// never took keyboard focus — the characters go nowhere — and a journey
    /// that did not check would fail three steps later, on a Sign In button
    /// that is disabled because the form it validates is empty. Reading the
    /// value back turns that into a failure on the line that typed.
    ///
    /// Two things about that read are worth knowing before changing it:
    ///
    ///   * **An empty field's value is its placeholder.** That is why the
    ///     deletions below are driven by the value's length and are harmless
    ///     when there is nothing to delete — a delete key against an empty
    ///     field does nothing — and why the check afterwards is for what was
    ///     typed rather than for the field having been empty first.
    ///   * **A `SecureField` publishes bullets, not characters.** Its value is
    ///     the right *length* and none of the right content, so equality is the
    ///     wrong assertion there and length is the strongest one available.
    @MainActor
    func replaceText(
        with text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        awaitExistence("a text field to type into", file: file, line: line)
        tap()
        if let existing = value as? String, !existing.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        typeText(text)

        let typed = value as? String
        let focusFailure = "The field did not take the typed text; it most likely never had keyboard focus."
        if elementType == .secureTextField {
            XCTAssertEqual(typed?.count, text.count, focusFailure, file: file, line: line)
        } else {
            XCTAssertEqual(typed, text, focusFailure, file: file, line: line)
        }
    }
}

extension XCUIApplication {

    /// The element carrying `identifier`, whatever kind of element it is.
    ///
    /// SwiftUI decides what a container becomes: a `List` is a collection view
    /// on one OS version and a table on another, a `ScrollView` is a scroll
    /// view until something inside it makes it an "other" element. A query
    /// aimed at `collectionViews[…]` therefore passes on one simulator in the
    /// matrix and fails on the next for a reason that has nothing to do with
    /// the app. Matching on the identifier across every type is the query that
    /// means what the test means.
    @MainActor
    func element(withIdentifier identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}
