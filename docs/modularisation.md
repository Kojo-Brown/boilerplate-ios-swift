# Modularisation

Phase 8 item 7. One target became four:

```
Core  <-  Networking  <-  Features  <-  BoilerplateiOSSwift
  ^--------------------------------------/
```

`Core` has no in-package dependency at all. `Networking` sees `Core`.
`Features` sees both. `BoilerplateiOSSwift` — the composition root, `@main`, and
the one subscriber to the session events — sees all three, and nothing sees it.

| Target | Path | Holds |
|--------|------|-------|
| `Core` | `Sources/Core` | Domain models, the error vocabulary, the concurrency primitives, SwiftData persistence, Keychain and biometrics, theming, navigation routes, the UDF contract |
| `Networking` | `Sources/Networking` | The API client and its endpoints, the token store, the repository decorator chain, the sync strategies |
| `Features` | `Sources/Features` | Five screens, their view models and feature services, and the design-system components they share |
| `BoilerplateiOSSwift` | `Sources/App` | `AppContainer`, `BoilerplateApp`, `AppNavigationView`, `SessionObserver` |

## What the split found

Directory names had been carrying the layering, and directory names are not
checked. Three edges pointed the wrong way and every one of them compiled:

- **`Core/DI/AppContainer` named all five features.** It is the composition
  root, so it has to name concrete types; what it must not be is *underneath*
  the things it names. It is in the app target now.
- **`Core/Repositories/UserRepository` named `UpdateProfileRequest`**, a type
  that lived in `Features/Auth/Models` next to `LoginRequest`. The transport
  layer reached up into a screen for the body of its own `PATCH`. The type
  moved down beside the repository that sends it.
- **`Core/Concurrency/Retry` classified `APIError`**, which lived in
  `Core/Network`. The retry policy is not wrong to know the error vocabulary —
  the vocabulary was in the wrong place. `APIError` is a `Core` model now, and
  `Networking` imports it like everything else does.

Two more were not wrong so much as unenforceable. `SessionObserver` sat in
`Core/Concurrency` and needed `TokenStoring` and `AppState`, which is a
composition-root concern wearing a concurrency file name; it moved next to
`AppContainer`. And `Features/BarcodeScanner` used `CameraService`,
`CameraPreviewView`, `CapturedFrame` and `CameraError` out of
`Features/TextRecognition` — one screen reaching into another, which is the
coupling this whole item exists to make visible. Those four moved to
`Features/Shared/Camera`, which both scanners may use and neither owns.

## Access levels: `package`, not `public`

Every declaration in `Core`, `Networking` and `Features` was `internal`, which
meant "visible to the whole app" right up until the moment the app stopped being
one module. They are `package` now — visible everywhere inside this Swift
package, invisible to anything that depends on it.

`public` was the other option and is the wrong one. This package is an app, not
a library: making 800 declarations public would publish an API surface no one
consumes and freeze it against the next refactor. `package` says exactly what is
true — these types are shared between the targets of this package and nowhere
else — and the compiler enforces it.

The one rule to remember when adding a type: **a struct another target
constructs spells its initialiser out.** Do not rely on the synthesised
memberwise one — that is the rule `public` structs have always had, and it costs
nothing to follow at `package` too. `TokenPair`, `SyncedUser`, `UserSignedIn`,
`ItemDetailView` and `ProfileFeature.State` all carry one for this reason, as do
the doubles the composition root builds (`MockAPIClient`, `MockUserRepository`,
and the rest).

Tests are not where this shows up: `@testable import` sees `internal`, so a
test constructs the type either way. Only another *target* — in practice
`Sources/App` — is on the far side of the boundary, which is what makes a
missing initialiser a CI failure rather than a test failure.

## How a screen gets its dependencies

A feature view used to take the whole `AppContainer`:

```swift
LoginView(container: container)   // before
```

That is one line and it was the edge that made the split impossible: a screen
that names `AppContainer` names, through it, every other screen in the app. So
each feature states what it needs and the root conforms:

```swift
// Sources/Features/Auth/LoginDependencies.swift
package protocol LoginDependencies {
    @MainActor func makeLoginViewModel() -> LoginViewModel
    @MainActor func makeSocialLoginViewModel() -> SocialLoginViewModel
    @MainActor func makeBiometricAuthViewModel() -> BiometricAuthViewModel
    var eventPublisher: any EventPublishing { get }
}

// Sources/App/AppContainer.swift
extension AppContainer: LoginDependencies, HomeDependencies, SettingsDependencies {}
```

The call site is unchanged in spirit — `AppNavigationView` still holds one
container and still writes one argument per screen, `LoginView(dependencies:
container)`. What changed is which way the arrow points. `LoginView` cannot
reach a camera or a sync strategy through `any LoginDependencies`, and a change
to what the barcode scanner needs cannot reach `LoginView` at all.

The second consequence is the one worth having: **a feature can now build its
own screens.** Each ships a preview double — `PreviewLoginDependencies`,
`PreviewHomeDependencies`, and so on — so `#Preview` and `PreviewProvider` no
longer reach for `AppContainer.preview`, which is in a target they cannot see.
A screen that could only be built from the composition root would be a module in
the manifest and not in fact.

`AppContainer.preview` still exists and is still the whole graph swapped for
doubles in one expression; it is what `AppNavigationView`'s own preview uses, and
what `ModularisationTests` checks the five conformances against.

## Why there is a script

`Tools/assert-module-boundaries.py`, wired into the lint job, fails on three
things the build cannot:

1. **A widened manifest.** `.target(dependencies:)` is the compiler's boundary,
   and adding a line to it is a one-line edit in a file nobody reads as
   carefully as a screen. The graph is written down in the script and the
   manifest is checked against it, so `Core` gaining an edge to `Networking`
   fails here rather than passing quietly.
2. **A transitive import.** Swift will find a type in a module that was loaded
   because something else imported it. That compiles today and stops compiling
   the day the intermediate edge is dropped, so a green build says nothing about
   which edges the source actually needs. Every file must import what it names.
3. **Feature-to-feature coupling.** `Features` is one target, so `BarcodeScanner`
   naming a `TextRecognition` type is an ordinary same-module reference and the
   compiler has no opinion about it. The script does: a feature may reach
   sideways only to `Features/Shared`.

It is a script rather than a test on purpose. It is syntactic — no toolchain, no
resolved packages, no simulator — so it runs on Linux, where the scheduled agent
that maintains this repository lives and where none of the five gates in
`CLAUDE.md` can execute. Along with the Sendable audit it is one of the two
checks that can be run before pushing rather than after.

Run it directly:

```bash
python3 Tools/assert-module-boundaries.py
```

## Known gaps

- **`Features` is one target, not five.** Feature isolation is enforced by the
  script, not by the compiler. Splitting each screen into its own target is the
  honest version and costs five more manifest entries plus a home for the
  navigation types; it was left out of this item because the item is the layer
  boundary and doing both at once would have made the diff unreadable.
- **`Networking` holds the sync strategies**, which are as much a persistence
  policy as a transport one — they read `UserPersistenceService` out of `Core`.
  They are here because they are the thing that decides whether a read goes to
  the network, and splitting a `Sync` target out to hold three files buys a
  manifest entry and no boundary that is not already checked.
- **No target has its own test target.** `ViewModelTests` still imports all four
  and tests all four, so nothing yet proves that `Core`'s tests pass without
  `Features` compiling. That is the check that would catch a dependency creeping
  back in through a test rather than through the source.
