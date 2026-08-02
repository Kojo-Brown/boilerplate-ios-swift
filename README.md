# boilerplate-ios-swift

> Swift 6 · SwiftUI · SwiftData · MLKit · Observation · Async/Await

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
| ML | MLKit text recognition + Vision |
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

ML Kit has no first-party Swift Package — Google publishes it for CocoaPods
only. Text recognition therefore resolves through
[`d-date/google-mlkit-swiftpm`](https://github.com/d-date/google-mlkit-swiftpm),
a community mirror of Google's xcframeworks, pinned to an exact version.

## Spec Progress
See [SPEC.md](./SPEC.md).
