# The XCUITest journey and the simulator matrix

One test drives the shipped app from the login screen, through sign-in, a
search, a push, the toolbar menu, a profile edit and out the other side — on
three simulators, on every pull request.

This page is about what that buys, what had to exist before it could run at
all, and the four ways a UI suite stops being a test while every run stays
green.

## What it catches that nothing else here does

The package's own suite is 73 files of Swift Testing and it reaches everything
it can reach *directly*: a view model is constructed with doubles, an action is
sent, a published property is read. `SnapshotTests` goes one step further and
renders seven views to bitmaps. None of it launches an application, because
there was no application to launch.

So three things had never been executed once in twelve phases:

* **`BoilerplateApp.init()`.** It opens a `ModelContainer`, builds the
  dependency graph, subscribes `SessionObserver` and
  `MetricKitDiagnosticSubscriber`, and registers a background task whose
  identifier must appear in the host's `Info.plist` — a registration that
  *raises* when it does not. Every one of those can fail at launch, and no unit
  test can reach any of them.
* **The session loop closing.** Signing in publishes a `UserSignedIn`;
  `SessionObserver` receives it, writes `AppState`, and `RootView` replaces its
  entire subtree. `EventBusTests` asserts the broadcast and
  `SessionObserverTests` asserts the handler. Neither can assert that the
  screen changed, because neither has a screen.
* **The accessibility tree.** `Tools/assert-accessibility-audit.py` says in its
  own docstring that it checks the *shape* of three defects in the source,
  because `_UIHostingView` publishes no elements in a unit-test process, and
  that reading the real tree "needs an XCUITest target with a host app, which
  this package does not have". It does now, and every query in the suite is a
  read of the published tree: a control missing from it fails here.

## The host app, and why there is one

`Package.swift` declares a library. SwiftPM has no product type that installs,
so it cannot produce the one thing an XCUITest needs — a `.app` bundle on a
simulator. `Tools/app-template/PrivacyInfo.xcprivacy` had spent two phases
being a template for an app target the repository did not have.

`UITestHost/` is that target, and it is deliberately the smallest thing that
can be one:

| File | What it is |
| --- | --- |
| `project.yml` | The XcodeGen spec: two targets, one scheme, the settings they need. |
| `Host/HostEntryPoint.swift` | `@main`, and one call to `BoilerplateApp.main()`. |
| `Host/Info.plist` | The keys the app reads at runtime, and the two it cannot launch without. |
| `UITests/` | The journey, the page objects and the waits. |

`@main` **moved** rather than being duplicated. It used to sit on
`BoilerplateApp`, which read naturally and could never produce a bundle: the
attribute synthesises the `main` symbol wherever it is, and in a SwiftPM
library that symbol lands in a static archive with nothing installable around
it. Two `@main` declarations linked into one binary are two definitions of
`_main` — a link error, not a warning — so there is exactly one and the host
owns it. `BoilerplateApp` became `public` for the same reason: the host is not
part of the package, so `package` would not reach it.

### Why the project is generated and not committed

A `project.pbxproj` is a few hundred lines of machine-written plist keyed by
opaque UUIDs. Nobody reviews a diff in one, every Xcode version rewrites parts
of it on open, and two branches that both touch it conflict in a way that
cannot be resolved by reading. `project.yml` is the same project in ninety
lines a reviewer can check against the settings it claims to set, so the spec
is committed and its output is in `.gitignore`.

The cost is one tool. CI installs it; locally:

```sh
brew install xcodegen
cd UITestHost && xcodegen generate
```

### The two `Info.plist` keys that are not optional

`BoilerplateApp`'s scene carries `.backgroundTask(.appRefresh(…))`.
`BGTaskScheduler` **raises** for an identifier absent from
`BGTaskSchedulerPermittedIdentifiers`, so a host without that key and
`UIBackgroundModes: [fetch]` is an app that cannot finish launching — which
would be the first thing every test in the suite reported and the last thing
any of them explained. `Tools/assert-ui-test-journey.py` holds the key equal to
`AppContainer.backgroundRefreshIdentifier`.

`UILaunchScreen` is the third, and it is subtler: without it iOS runs the app
in iPhone compatibility mode on an iPad — a letterboxed window, a *compact*
horizontal size class, and `HomeView` resolving to the list layout on the one
device in the matrix that exists to render the grid. An empty dictionary is
enough, and `TARGETED_DEVICE_FAMILY: "1,2"` is the other half.

## What the app does differently under test

Exactly three things, and each is a substitution this package already had.
`UITestLaunch.isActive` reads one launch argument and
`BoilerplateApp.init()` acts on it:

| | Shipped | Under test |
| --- | --- | --- |
| Dependency graph | `AppContainer.live(…)` | `AppContainer.preview` — every collaborator its double |
| Store | `PersistenceController.makeContainer()` | `…makeInMemoryContainer()`, same schema, same migration plan |
| Appearance preference | read from `UserDefaults` | cleared at launch |

Everything above the graph is untouched: the entry point, the scene,
`RootView`'s branch on the session, the coordinator-backed `NavigationStack`,
every view and every view model. That is the part under test, and a seam
reaching any further up would be a suite exercising a second app.

The argument is `UI_TESTING`, with **no leading dash**, and that is
load-bearing. `UserDefaults` parses the process arguments as its
highest-priority domain and reads any `-key value` pair there, so a lone
`-ui-testing` would take the next launch argument as its value — or, last in
the list, be swallowed. A flag whose presence depends on its position is a flag
that will one day be absent for no visible reason. The audit fails on a dash.

`MockAuthService` accepts anything `LoginViewModel.isFormValid` lets through
(an `@` and eight characters) after 100ms; `MockSyncStrategy` answers with
`mock@example.invalid` / `Mock User`; `HomeViewModel`'s stub returns ten rows
after 600ms. Nothing reaches the network, and the journey's assertions are
written against those values.

## Why identifiers and not labels

A UI test can find an element by its label, by its position in the tree, or by
its identifier. Only the last is a name:

* **The label is prose.** It is localised, it is what a reader hears, and a
  copy edit or a runner in another language turns the query into "the button is
  not there" rather than "the button is called something else".
  `docs/localisation.md` is the whole of why that is not hypothetical here.
* **The position keeps passing while pointing somewhere else.**
  `app.buttons.element(boundBy: 2)` is the query most worth avoiding.
* **The identifier** is not localised, not rendered, not read out by VoiceOver
  and invisible to the snapshot gate. It exists for this.

`AccessibilityID` is declared twice: `package` in `Core` for the views, and
again in `UITestHost/UITests/Support/` because the test bundle is an Xcode
target and cannot see `package` declarations in a SwiftPM one. The audit holds
the two lists to being identical, name for name and value for value, and
separately fails on an identifier that no view applies — a constant nothing
carries is a query that can only ever time out, which reads exactly like a
regression in the screen it was looking at.

The one exception is a Home row, which is queried by label because the row's
name *is* its data: `HomeViewModel.catalogue` mints "Item 1" through "Item 10",
and an identifier per row would have to encode the same string. The other is
the navigation bar's back button, which `NavigationStack` builds — there is
nowhere in `Sources/` to hang an identifier on it, and its only name is the
previous screen's localised title, so `NavigationBarScreen.goBack()` takes the
leading button of the bar and says so.

## The matrix, and what makes it one

Three devices, each here because it can disagree with the others:

| Device | Why |
| --- | --- |
| iPhone 16 | The compact baseline, and the device the rest of CI uses — so a failure only here is about the journey, not the device. |
| iPhone SE (3rd generation) | The smallest screen still supported. A row, a menu or a form that fits on a 16 and not on an SE is a real defect, invisible in a preview and in a snapshot taken at one size. |
| iPad Pro 13-inch (M4) | A *regular* horizontal size class — the other branch of `HomeView.content`. Nothing had rendered `itemGrid` on a device before this item. |

`fail-fast: false`, because the useful information is *which* devices
disagreed. A matrix that cancels its siblings on the first red leg reports one
failure and hides whether the other two would have passed — the difference
between "the grid branch is broken" and "the journey is broken".

### How a leg knows which layout to expect

It does not. There are two tests in `AdaptiveLayoutUITests`, each asserting one
outcome, and the workflow passes `-skip-testing:` for the one that does not
apply to that leg's device. Nothing is read from the environment and nothing is
inferred from the device, which rules out the two failure modes that matter: a
test that asked the device what to expect would be asserting its own copy of
the thing under test, and a test that read an expectation out of an environment
variable would skip itself — silently, and still green — the day the variable
stopped arriving.

It also fails in the safe direction. `xcodebuild` ignores an unknown
`-skip-testing:` identifier, so a typo makes the inapplicable test *run* and go
red; it cannot leave a leg asserting nothing. The audit checks the identifiers
name real tests, and that each layout test is skipped by at least one leg and
run by at least one.

Each leg therefore carries two names rather than one: `skip`, the layout test
its device cannot satisfy, and `expect`, the one it must. `expect` exists
because of the single way this job can report success having established
nothing — `xcodebuild test-without-building` exits 0 for a run that executed no
tests, and there are ordinary ways to get one: a scheme whose test action lost
its target, a `-skip-testing:` that matched more than it was meant to, a bundle
that never got installed. None of them produces a failure; they produce a short
green log. So the step after the run greps the log for the three tests the leg
was supposed to execute — the journey, the refused form, and its own `expect` —
and fails if any is absent. The audit holds the pair to being the two layout
tests, one each, since a leg that expected what it skipped would assert that a
skipped test had run.

The grep is a substring match rather than a parse of the result bundle on
purpose: `xcodebuild` has spelled its per-test lines three different ways across
Xcode releases and the method name is in all three.

### Picking the simulator

`.github/actions/select-simulator` does it, and this item gave it two inputs:
`device-family`, which is a requirement — a leg that asked for an iPad and was
handed an iPhone is a leg silently running its sibling's test, so an image with
nothing in the family fails the step — and `preferred-device`, which is a
preference, because runner images rename and retire models and the layout
follows from the size class rather than from the model. A fallback within the
family is a warning, not a failure.

## The four ways a UI suite stops being a test

Each of these is checked by `Tools/assert-ui-test-journey.py`, in the lint job,
on Linux, with no toolchain:

1. **A query for an identifier nothing carries.** It does not fail fast. It
   waits out its timeout and reports that the screen does not have the element.
2. **A mismatched launch argument.** The worst of the four, because it is
   silent *and* plausible: the app launches with the live graph, the journey
   reaches for a network it does not have, and the suite reports as a flake.
3. **A sleep.** A wait tuned until it passed on one machine. There are none in
   the bundle: every wait is a `waitForExistence` against the thing the
   previous step was supposed to produce, so a broken step fails as "the Home
   list never appeared" rather than as a later assertion against a screen that
   was not ready.
4. **A test skipped by every leg.** An assertion nothing performs. The audit
   also holds each leg's `skip` and `expect` to being the two layout tests, one
   each, which is what makes the post-run grep above a check rather than a
   formality.

A fifth is checked by the suite itself rather than by the audit:
`XCUIElement.replaceText(with:)` reads the field's value back after typing,
because `typeText` reports no error when the field never took keyboard focus —
the characters go nowhere, and the journey would fail three steps later on a
Sign In button that is disabled because the form it validates is empty. Two
things make that read tricky and both are commented where it happens: an empty
field's value is its *placeholder*, and a `SecureField` publishes bullets, so
length is the strongest assertion available there.

## Running it

CI, per leg, is in `.github/workflows/ci.yml`'s `ui-test` job. Locally:

```sh
cd UITestHost
xcodegen generate
xcodebuild test \
  -project UITestHost.xcodeproj \
  -scheme UITestHost \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skip-testing:UITests/AdaptiveLayoutUITests/testHomeResolvesTheGridLayoutOnARegularWidth
```

Swap the `-skip-testing:` line for the list test and the destination for an
iPad to run the other leg.

A failure's answer is in the result bundle rather than in the log: the
automatic screenshot of the screen as it was, the accessibility tree that was
queried, and the `XCTContext.runActivity` step the journey had reached. CI
uploads it as `ui-test-<device>-<run>` on every run, pass or fail. A log line
saying an element did not exist is a sentence; the bundle is the answer.

## What this still does not do

* **Nothing here is run on a device.** The matrix is simulators, and a
  simulator does not have a camera, a Secure Enclave, a real biometric sensor
  or a cellular radio. The scanner screens, Face ID sign-in and App Attest are
  all reachable from the host and none of them is in the journey.
* **It does not read what VoiceOver would say.** It reads the published tree,
  which is strictly more than `Tools/assert-accessibility-audit.py` could — but
  an identifier is not a label and existence is not an announcement. Holding
  the labels, values, traits and rotor to what a reader would hear is the next
  thing the host makes possible, and it is not done.
* **The journey signs in with the doubled graph.** It therefore says nothing
  about the live `APIClient`, its pinning, or the attestor in front of it;
  those have their own suites and their own docs.
* **One journey.** Settings' appearance picker, pull-to-refresh, the row
  swipe-to-delete and the two scanner screens are all reachable and none is
  covered. Adding a screen to `Screens.swift` and a test beside the journey is
  the shape of that work.
