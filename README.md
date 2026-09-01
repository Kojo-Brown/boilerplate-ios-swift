# boilerplate-ios-swift

> Swift 6 · SwiftUI · SwiftData · Vision · Observation · Async/Await

Modern iOS app starter with clean architecture and ML features.

## Stack

| Layer | Tech |
|-------|------|
| Language | Swift 6 |
| UI | SwiftUI |
| Navigation | NavigationStack + Coordinator |
| Persistence | SwiftData |
| Network | URLSession (async/await) |
| Auth | Sign in with Apple + Google |
| ML | Vision (text recognition + barcode scanning) |
| Testing | XCTest + Swift Testing |

## Quick Start

1. Open `Package.swift` in Xcode 16+ — this is a Swift Package, there is no
   `.xcodeproj` to open
2. Let Xcode resolve dependencies (or run `swift package resolve` first)
3. Select simulator (iOS 17+)
4. Add `Config.xcconfig` with your API_URL
5. Build & Run

### Dependencies

`Package.resolved` is tracked; resolve from it rather than re-resolving ranges.

The only third-party dependency is `GoogleSignIn-iOS`. On-device ML uses
Apple's Vision framework, which ships with the SDK.

Text recognition used to run on Google's ML Kit, reached through a community
mirror of Google's xcframeworks. That is no longer viable: ML Kit for iOS ships
no `arm64` slice for the simulator, so the package could not link on an Apple
Silicon Mac — which is every current Mac and every current CI runner. Building
the package `x86_64` under Rosetta links and then aborts at launch. Vision does
the same job with no dependency, and additionally reports a per-observation
confidence that ML Kit's iOS API does not expose.

## Architecture

Four targets, in a straight line:

```
Core  <-  Networking  <-  Features  <-  BoilerplateiOSSwift
  ^--------------------------------------/
```

| Target | Path | Holds |
|--------|------|-------|
| `Core` | `Sources/Core` | Models, errors, concurrency primitives, persistence, Keychain, theming, routes, the UDF contract |
| `Networking` | `Sources/Networking` | API client, endpoints, token store, repository decorators, sync strategies |
| `Features` | `Sources/Features` | The five screens and the components they share |
| `BoilerplateiOSSwift` | `Sources/App` | `AppContainer`, `@main`, navigation host, session observer |

`AppContainer` (`Sources/App/`) is the composition root: the only place that
names a live implementation. It is built once in `BoilerplateApp` and threaded
down the view tree, so no initialiser in the package carries a default
collaborator and no view knows what is behind the protocol it uses. Each screen
declares what it wants from it — `LoginDependencies`, `HomeDependencies` and so
on — and the container conforms, so a feature names no other feature and can
build its own previews from doubles it ships itself.

- [docs/modularisation.md](./docs/modularisation.md) — the target graph, why the
  shared code is `package` rather than `public`, and the script that keeps the
  boundaries from drifting
- [docs/dependency-injection.md](./docs/dependency-injection.md) — the container,
  and the two shapes it deliberately is not
- [docs/solid.md](./docs/solid.md) — SOLID audit of the repository and service
  layers, and which findings are still open
- [docs/sync-strategy.md](./docs/sync-strategy.md) — the pluggable read policy
  over the API and the local store, and what it left for Phase 9
- [docs/offline-first.md](./docs/offline-first.md) — the policy that inverts it:
  SwiftData as the source of truth, a refresh window stamped on the row so a
  launch can skip the request, and the two store bugs that only mattered once a
  read was answered from disk
- [docs/conflict-resolution.md](./docs/conflict-resolution.md) — what happens
  when the row and the response disagree about the same profile: a
  server-assigned revision, the nine decisions a merge can reach, and why a read
  falls back to the row where a write fails
- [docs/background-refresh.md](./docs/background-refresh.md) — keeping that row
  fresh while the app is not running: which `BGTaskRequest` can carry a
  constraint and which cannot, why the failure count has to outlive the process,
  and the three defects in the handler everyone writes first
- [docs/migrations.md](./docs/migrations.md) — opening the store the *last*
  build wrote: the versioned schemas, the migration plan over them, and why two
  changes that already migrated themselves still needed writing down
- [docs/unidirectional-data-flow.md](./docs/unidirectional-data-flow.md) — the
  `State` + `Action` + `Effect` contract, the store that runs it, and the screen
  it replaced five stored properties on
- [docs/concurrency.md](./docs/concurrency.md) — the structured-concurrency
  utilities in `Sources/Core/Concurrency`

## Spec Progress
See [SPEC.md](./SPEC.md).
