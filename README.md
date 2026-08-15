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

`AppContainer` (`Sources/Core/DI/`) is the composition root: the only place that
names a live implementation. It is built once in `BoilerplateApp` and threaded
down the view tree, so no initialiser in the package carries a default
collaborator and no view knows what is behind the protocol it uses.
`AppContainer.preview` swaps the whole graph for hand-written doubles in one
expression, which is what every `#Preview` and preview provider uses.

- [docs/dependency-injection.md](./docs/dependency-injection.md) — the container,
  and the two shapes it deliberately is not
- [docs/solid.md](./docs/solid.md) — SOLID audit of the repository and service
  layers, and which findings are still open
- [docs/concurrency.md](./docs/concurrency.md) — the structured-concurrency
  utilities in `Sources/Core/Concurrency`

## Spec Progress
See [SPEC.md](./SPEC.md).
