import XCTest

/// What the simulator matrix is for.
///
/// Phase 12 item 4. Running one journey on three simulators is only worth the
/// minutes if the simulators can disagree, and here they genuinely can:
/// `HomeView.content` branches on the horizontal size class, so the same code
/// renders a `List` on an iPhone and a `LazyVGrid` on an iPad — two different
/// view trees, two different row types, and until this item nothing had ever
/// rendered the second one outside a preview. `AdaptiveLayoutTests` in the
/// package asserts the column arithmetic and `FlowLayoutRenderTests` asserts a
/// layout's geometry; neither can say which branch a real device takes, because
/// neither has a device.
///
/// ## How a leg knows which layout to expect
///
/// It does not. There are two tests, each asserting one outcome, and
/// `.github/workflows/ci.yml` passes `-skip-testing:` for the one that does not
/// apply to that leg's device. Nothing is read from the environment and nothing
/// is inferred from the device, which rules out the two failure modes that
/// matter here: a test that asked the device what to expect would be asserting
/// its own copy of the thing under test, and a test that read an expectation
/// out of an environment variable would skip itself — silently, and still
/// green — the day the variable stopped arriving.
///
/// The arrangement fails in the safe direction. A mistyped `-skip-testing:`
/// identifier is ignored by `xcodebuild`, so the inapplicable test *runs* and
/// goes red; it cannot leave a leg asserting nothing.
/// `Tools/assert-ui-test-journey.py` holds the workflow's identifiers to naming
/// tests that exist, and holds each of the two below to being skipped by at
/// least one leg and run by at least one.
final class AdaptiveLayoutUITests: XCTestCase {

    @MainActor
    func testHomeResolvesTheListLayoutOnACompactWidth() {
        continueAfterFailure = false
        let home = UITestFlow.signIn()

        XCTAssertTrue(
            home.list.exists,
            "A compact horizontal size class must render `itemList`."
        )
        XCTAssertFalse(
            home.grid.exists,
            "The two branches of `HomeView.content` are exclusive; the grid must not also be in the tree."
        )
    }

    @MainActor
    func testHomeResolvesTheGridLayoutOnARegularWidth() {
        continueAfterFailure = false
        let home = UITestFlow.signIn()

        XCTAssertTrue(
            home.grid.exists,
            """
            A regular horizontal size class must render `itemGrid`. A list here on an iPad usually \
            means the host was launched in iPhone compatibility mode, which is what `UILaunchScreen` \
            and TARGETED_DEVICE_FAMILY in UITestHost/ exist to prevent.
            """
        )
        XCTAssertFalse(
            home.list.exists,
            "The two branches of `HomeView.content` are exclusive; the list must not also be in the tree."
        )
    }
}
