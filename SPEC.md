# Spec: boilerplate-ios-swift

> Spec-driven. Mark `[x]` only after pushing.

## Phase 1 — Foundation
- [x] Swift 6 + Xcode 16 project targeting iOS 17+
- [x] SwiftUI App lifecycle with `@main`
- [x] Swift Package Manager dependencies
- [x] Project structure: Features/, Core/, Shared/
- [x] SwiftLint + SwiftFormat config

## Phase 2 — Architecture
- [ ] Observation framework (`@Observable`) for ViewModels
- [ ] Coordinator pattern for navigation with NavigationStack
- [ ] Repository pattern: `UserRepository` protocol + live/mock impl
- [ ] Swift Concurrency: async/await, `Task`, `AsyncStream`

## Phase 3 — Network & Persistence
- [ ] URLSession typed API client with JWT Bearer + refresh
- [ ] `Codable` model layer with `@CodingKey` strategy
- [ ] SwiftData persistence layer (User entity)
- [ ] Keychain wrapper for secure token storage

## Phase 4 — Auth & ML
- [ ] Sign in with Apple + Google Sign-In
- [ ] MLKit text recognition with camera integration
- [ ] Vision framework: barcode + QR scanning overlay
- [ ] Face ID / Touch ID biometric auth wrapper

## Phase 5 — UI Components
- [ ] Design system: `AppButton`, `AppTextField`, `LoadingView`
- [ ] Dark/light mode via `@Environment(\.colorScheme)`
- [ ] Adaptive layout with `GeometryReader` + size classes

## Phase 6 — Testing & DevOps
- [ ] XCTest unit tests for ViewModels with `@MainActor`
- [ ] SwiftUI Preview tests with `PreviewProvider`
- [ ] GitHub Actions: build + test on macOS runner
- [ ] Fastlane setup for TestFlight deploy
