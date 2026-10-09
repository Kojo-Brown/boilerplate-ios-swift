# Testing: Swift Testing, XCTest, and which one a suite can fail in

The suite is Swift Testing. 1,030 `@Test` cases across 73 files, and no
`XCTestCase` left in the bundle.

That last sentence is the part worth being careful about, because the two
frameworks are *designed* to coexist in one test target, and the item that
produced this page — Phase 12 item 1, "migrate to Swift Testing alongside
XCTest" — is exactly the kind of work where the coexistence is what bites.

## What the migration actually removed

Six files, 1,136 lines, 127 `func test…` methods:
`HomeViewModelXCTests`, `LoginViewModelXCTests`,
`BiometricAuthViewModelXCTests`, `BarcodeScannerViewModelXCTests`,
`TextRecognitionViewModelXCTests`, `SocialLoginViewModelXCTests`.

None of them used anything XCTest alone provides. Each one was a mirror of a
Swift Testing suite that already existed for the same type, written in the
other dialect: `XCTAssertEqual(sut.items.count, firstCount)` beside
`#expect(sut.items.count == firstCount)`, the same scenario, the same
expectation, twice. Of the 127 methods, 87 were a second spelling of an
assertion the Swift Testing suite already made; 40 asserted something it did
not, and those 40 are now in it — per suite: Home 13, Biometric 7, Social 7,
Login 6, TextRecognition 5, Barcode 2. Two of Home's thirteen landed in
`HomeViewModelConcurrencyTests` rather than `HomeViewModelTests`; see the
placement rule at the end of this page.

Two of the 40 were strengthened on the way across, because they could not
fail as written:

```swift
XCTAssertFalse(error.errorDescription?.isEmpty == true)
```

A nil description makes `errorDescription?.isEmpty == true` false as well, so
`XCTAssertFalse` is satisfied exactly when there is no message to show the
user. They are `try #require(error.errorDescription)` now, which fails on nil
and hands the non-optional value on.

### The duplicates were not insurance

`SocialLoginViewModelXCTests` is in SPEC.md four times, and never for a defect
it caught. It is the suite that blew XCTest's two-minute per-test execution
allowance on runs 30897280228, #83, and twice during Phase 9 item 6 and Phase
10 item 3 — each time because something elsewhere in the bundle was holding
the main actor (a `while !done { await Task.yield() }` wait, a
`RunLoop.current.run(until:)`) while this `@MainActor` suite needed it to
construct an `ASPresentationAnchor()`.

The main-actor stalls were real and each was fixed where it lived. What XCTest
added was the amplifier: a per-test wall-clock allowance that is on by default
and turns any stall anywhere in the bundle into a *failed test* in whichever
`@MainActor` XCTest suite happened to be waiting. Swift Testing has no implicit
allowance — `.timeLimit` is opt-in, and is applied per suite where this
repository wants it — so the Swift Testing twin of that suite, constructing the
same `ASPresentationAnchor()` in the same bundle, has never been one of these
failures.

Removing the mirror does not make a main-actor stall safe. It stops a stall
from being reported as a false failure in an unrelated suite.

## The three ways a test here can silently stop being able to fail

`Tools/assert-test-framework.py` runs in the lint job and fails on each of
these. All three compile, link, run, and report success.

**1. An XCTest assertion inside a `@Test`.** `XCTAssertEqual` and friends
report to the *current `XCTestCase`*. Inside a Swift Testing test there is not
one, so the failure is recorded against nothing and the test passes.

**2. A `#expect` inside an `XCTestCase`.** The mirror image: the expectation is
recorded against no current Swift Testing test, so a false expectation cannot
fail the `XCTestCase` it sits in.

**3. A `func testSomething()` left behind in a migrated suite.** This is the
one that costs coverage. XCTest discovered test methods by that name prefix;
Swift Testing discovers the `@Test` attribute and nothing else. Change
`final class FooTests: XCTestCase` to `struct FooTests` and every method in it
still compiles, still reads as a test, and is never called again. A migration
that did this to one file would leave the file looking full of tests, the suite
count unchanged, and the assertions gone.

The script also fails a `*Tests.swift` file with no test in it at all, which is
the same mistake one step further along, and a file that imports both
frameworks — the mixed file is where a cross-framework assertion gets written.

It is not a Swift test, and cannot be: the failure it catches is tests not
running. It is syntactic, so it needs no toolchain, no resolved packages and no
simulator — it is one of the few gates in this repository that runs on the
scheduled agent's Linux box as well as in CI. Each of its five rules was
checked against the defect it names before it was wired in.

## When to reach for XCTest anyway

XCTest is not banned, and the test target still links it. Two things Swift
Testing cannot express:

* **A performance baseline.** `measure { }` with `XCTClockMetric` /
  `XCTMemoryMetric`, and the recorded baseline that makes a regression fail
  rather than merely print. Swift Testing has no performance API.
* **A UI journey.** `XCUIApplication` and the whole XCUITest surface are
  XCTest-only. Phase 12 item 4 is that journey, and it will arrive as
  `XCTestCase`.

A new `XCTestCase` has to be recorded in `ALLOWED_XCTEST_SUITES` in
`Tools/assert-test-framework.py` with the reason XCTest is the right choice
there. The table is checked in both directions: an unrecorded suite fails, and
so does an entry whose suite is gone, because a suppression that outlives the
code it was granted for is how an allowlist turns into a rubber stamp. It is
empty today, and that is the honest state of the tree rather than a policy
against XCTest.

## Conventions in the Swift Testing suites

* A suite is a `struct`, and `@MainActor` on it when the type under test is.
  Every case gets a fresh instance, so there is no `setUp`/`tearDown` and no
  shared mutable state between cases.
* Test names say what is true, not which method is called:
  `refreshKeepsRowIdentityStable`, not `testRefresh`. The `test` prefix carries
  no meaning to Swift Testing, and a method still named that way is the defect
  in rule 3 above.
* `#expect` for an assertion that should be recorded and let the test carry on;
  `try #require` when the test cannot continue without the value, which is also
  how an optional gets unwrapped.
* `Issue.record` for a path that should not have been reached — see
  `MockBiometricAuthServiceTests.stubbedErrorIsThrown`.
* Suites that drive SwiftUI through a window are `.serialized` with an explicit
  `.timeLimit(.minutes(1))`. A visible `UIWindow` is process-wide state, and
  Swift Testing runs suites in parallel by default. See
  [docs/view-identity.md](./view-identity.md) for what that cost before it was
  understood.
* **A test that starts something that outlives it goes in the suite built for
  that, not beside the synchronous tests for the same type.** A live
  `PollingStream`, a window, a subscription: all of them keep running after the
  case that made them returns, and Swift Testing runs the rest of the bundle
  alongside. `HomeViewModelConcurrencyTests` and `SessionObserverTests` are
  where those live, and both carry `.timeLimit(.minutes(1))` and wait by
  polling until the state they assert on holds still — never by sleeping a
  fixed number of milliseconds, which asserts a deadline belonging to the
  runner rather than anything about the code. Phase 12 item 1 got this wrong
  on its first push: it ported three `HomeViewModel` live-update cases into the
  plain suite, where neither the backstop nor the idiom applies.
