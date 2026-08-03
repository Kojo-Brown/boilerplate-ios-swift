# Spec: boilerplate-ios-swift

> Spec-driven. Mark `[x]` only after pushing.

## Phase 0 — Green Baseline (blocks all feature work)
- [x] Confirm the Xcode project resolves all Swift Package dependencies at pinned versions — the graph could never have resolved: `google-mlkit/ml-kit-ios` does not exist and neither product it was asked for is real (PR #19)
- [x] Get build, SwiftLint (strict), and the XCTest suite passing locally on a simulator — the package had never been compiled, linked or run; ML Kit could not link on any Apple silicon simulator so text recognition moved to Apple's Vision framework, and the test process was dying on an orphaned `ModelContext` (PR #21)
- [ ] Promote `workflow-templates/ios-ci.yml` to `.github/workflows/` and confirm it runs green on a PR
- [ ] Confirm the project builds under Swift 6 strict concurrency with no warnings

Item 1 complete as of PR #19 (2026-08-02). `dependency-resolution.yml` resolves
the full graph on a macOS runner — 9 pins, no version conflicts, every ML Kit
xcframework downloaded and checksum-verified — and fails if `Package.resolved`
drifts from what resolution produces. `Package.resolved` is committed for the
first time.

Three things had to be false at once for the old manifest to work. Google ships
ML Kit for iOS through **CocoaPods only**, so `google-mlkit/ml-kit-ios` was never
a repository at any version; `MLKitTextRecognitionV2` and `MLKitVision` are not
products of any published ML Kit package; and `.gitignore` carried a `*.resolved`
rule that ignored the lockfile. Text recognition now resolves through
`d-date/google-mlkit-swiftpm`, pinned `exact: "9.0.0"` — a floating range on a
binary mirror swaps the shipped framework with no source diff to review.
`GoogleSignIn-iOS` resolved to 7.1.0, and the two competing `gtm-session-fetcher`
requirements (GoogleSignIn's `~> 3.3` vs the mirror's `exact 3.5.0`) met at 3.5.0
rather than deadlocking.

**Every gate in CLAUDE.md is unrunnable in the scheduled agent's environment,
and that is not a shortcut taken by choice.** It runs on Linux: `swift`,
`xcodebuild` and `swiftlint` are all absent and Xcode cannot be installed there,
so zero of the five gates can execute locally. CI is the source of truth for this
repo, the same conclusion `boilerplate-android-kotlin` reached for its own item 1.
Future runs should expect the same and read the PR checks, not a local run.

Item 2 complete as of PR #21 (2026-08-03). `gates.yml` builds, lints and runs the
suite on an arm64 iOS Simulator; all four checks are green. Every gap item 1
recorded is closed: `.swiftlint.yml` now exists (84 violations fixed, none
configured away), the scheme is discovered from `xcodebuild -list -json` rather
than guessed at `-scheme App`, and the package has been compiled and run for the
first time.

The ML Kit escape hatch item 1 described was taken, and not by preference. The
mirror builds "`arm64` for iphoneos and `x86_64` for iphonesimulator only", so
the test bundle could not link on any Apple silicon Mac or macOS runner; building
the package `x86_64` under Rosetta links and then aborts 195/195 tests at launch.
`TextRecognitionService` now uses Vision, which drops the dependency graph from
nine pins to four and vends a real per-observation confidence that ML Kit's iOS
API does not.

The crash that followed took five diagnoses, and the four wrong ones each found a
real defect: an optional-key-path `SortDescriptor`, a `UUID` `#Predicate`, and
`@Attribute(.unique)` on an in-memory store are all genuinely unreliable in
SwiftData. The actual cause was lifetime — the test suite built its
`ModelContainer` as a local and kept only `container.mainContext`, and a context
does not keep its container alive, so every test ran against an orphaned context.
SwiftData reports that by trapping rather than throwing, which is why one bug
presented as ~200 tests "failing" that had never run.

Carried into later items: `.serialized` on the persistence suite is retained but
is **not** known to be needed — it was added on a theory that turned out wrong and
did not stop the crash; removing it is a one-line experiment. And no `#Predicate`
survives in the package, because `UserEntity.id` is a `UUID` and SwiftData traps
comparing one; making predicates usable means changing the model's identifier
type, which is a model change and its own item.

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
- [x] Text recognition with camera integration — implemented on ML Kit, then moved to
  Apple's Vision framework in PR #21: ML Kit ships no arm64 simulator slice, so it could
  not link on any Apple Silicon Mac or CI runner
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
