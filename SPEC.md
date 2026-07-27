# Spec: boilerplate-ios-swift

> Spec-driven. Mark `[x]` only after pushing.

## Phase 0 — Green Baseline (blocks all feature work)
- [ ] Confirm the Xcode project resolves all Swift Package dependencies at pinned versions
- [ ] Get build, SwiftLint (strict), and the XCTest suite passing locally on a simulator
- [ ] Promote `workflow-templates/ios-ci.yml` to `.github/workflows/` and confirm it runs green on a PR
- [ ] Confirm the project builds under Swift 6 strict concurrency with no warnings

## Phase 1 — Foundation
- [x] Swift 6 + Xcode 16 project targeting iOS 17+
- [x] SwiftUI App lifecycle with `@main`
- [x] Swift Package Manager dependencies
- [x] Project structure: Features/, Core/, Shared/
- [x] SwiftLint + SwiftFormat config

## Phase 2 — Architecture
- [x] Observation framework (`@Observable`) for ViewModels
- [x] Coordinator pattern for navigation with NavigationStack
- [x] Repository pattern: `UserRepository` protocol + live/mock impl
- [x] Swift Concurrency: async/await, `Task`, `AsyncStream`

## Phase 3 — Network & Persistence
- [x] URLSession typed API client with JWT Bearer + refresh
- [x] `Codable` model layer with `@CodingKey` strategy
- [x] SwiftData persistence layer (User entity)
- [x] Keychain wrapper for secure token storage

## Phase 4 — Auth & ML
- [x] Sign in with Apple + Google Sign-In
- [x] MLKit text recognition with camera integration
- [x] Vision framework: barcode + QR scanning overlay
- [x] Face ID / Touch ID biometric auth wrapper

## Phase 5 — UI Components
- [x] Design system: `AppButton`, `AppTextField`, `LoadingView`
- [x] Dark/light mode via `@Environment(\.colorScheme)`
- [x] Adaptive layout with `GeometryReader` + size classes

## Phase 6 — Testing & DevOps
- [x] XCTest unit tests for ViewModels with `@MainActor`
- [x] SwiftUI Preview tests with `PreviewProvider`
- [x] GitHub Actions: build + test on macOS runner
- [x] Fastlane setup for TestFlight deploy

## Phase 7 — Swift Concurrency Mastery
- [ ] Strict concurrency checking enabled with `Sendable` conformance across the codebase
- [ ] Actors for shared mutable state + a documented actor-reentrancy pitfall
- [ ] `@MainActor` isolation rules and safe hops off the main actor
- [ ] Structured concurrency: `TaskGroup`, cancellation propagation, and `withTaskCancellationHandler`
- [ ] `AsyncSequence`/`AsyncStream` wrapping a delegate-based API with backpressure notes
- [ ] Global actors and custom executors for a serial background domain
- [ ] Immutability: value semantics, `let`-first modelling, and copy-on-write inspection
- [ ] Async retry with exponential backoff and jitter, plus a timeout combinator

## Phase 8 — Architecture & Patterns
- [ ] SOLID audit of the repository/service layers documented in `docs/solid.md`
- [ ] Protocol-oriented dependency inversion with a lightweight DI container
- [ ] Factory + Strategy: pluggable `SyncStrategy` resolved at composition root
- [ ] Decorator pattern: repository wrappers adding cache, retry, and telemetry
- [ ] Observer pattern: typed event bus on `AsyncStream`
- [ ] Unidirectional data flow: single `State` + `Action` + `Effect` contract per feature
- [ ] Swift Package modularisation: `Core`, `Networking`, `Features` targets with boundaries

## Phase 9 — Offline-First & Data
- [ ] Offline-first repository: SwiftData as source of truth with a network refresh policy
- [ ] Background refresh via `BGTaskScheduler` with constraints and retry
- [ ] Conflict resolution with a version field and a documented merge policy
- [ ] SwiftData migration plan with versioned schemas and migration tests
- [ ] Idempotent sync requests with client-generated keys
- [ ] Pagination with cursor tokens and a prefetch-on-scroll strategy

## Phase 10 — SwiftUI Performance & UI
- [ ] View-identity and `Equatable` conformance to cut redundant body evaluations
- [ ] `LazyVStack` performance: stable ids, `.id()` pitfalls, and prefetch
- [ ] Instruments profiling walkthrough: hitches, hangs, and a fixed hotspot
- [ ] Custom `Layout` protocol implementation for a measure-dependent component
- [ ] Matched-geometry transitions + interactive dismissal
- [ ] Full accessibility pass: labels, traits, Dynamic Type, VoiceOver rotor
- [ ] Localisation with String Catalogs including plurals and an RTL pass

## Phase 11 — Security & Release
- [ ] Keychain access-control flags with biometric gating, never `UserDefaults` for tokens
- [ ] Certificate pinning via `URLSessionDelegate` with a rotation plan
- [ ] App Attest / DeviceCheck integration for request attestation
- [ ] Jailbreak and tamper heuristics with a documented threat model
- [ ] Fastlane Match signing with credentials from the CI secret store only
- [ ] Privacy manifest + required-reason API declarations
- [ ] MetricKit crash and hang reporting pipeline

## Phase 12 — TDD & Advanced Testing
- [ ] Migrate to Swift Testing (`@Test`, `#expect`) alongside XCTest
- [ ] TDD kata: one use-case built red→green→refactor, one commit per step
- [ ] Snapshot tests with a CI diff gate
- [ ] XCUITest journey on a simulator matrix in CI
- [ ] Test doubles via protocol fakes replacing network and persistence
