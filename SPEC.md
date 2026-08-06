# Spec: boilerplate-ios-swift

> Spec-driven. Mark `[x]` only after pushing.

## Phase 0 — Green Baseline (blocks all feature work)
- [x] Confirm the Xcode project resolves all Swift Package dependencies at pinned versions — the graph could never have resolved: `google-mlkit/ml-kit-ios` does not exist and neither product it was asked for is real (PR #19)
- [x] Get build, SwiftLint (strict), and the XCTest suite passing locally on a simulator — the package had never been compiled, linked or run; ML Kit could not link on any Apple silicon simulator so text recognition moved to Apple's Vision framework, and the test process was dying on an orphaned `ModelContext` (PR #21)
- [x] Promote `workflow-templates/ios-ci.yml` to `.github/workflows/` and confirm it runs green on a PR — the template could never have run (invented scheme, hardcoded Xcode path, a simulator runtime that is gone, and a lint step that exited 0 when swiftlint was absent), so `gates.yml` was folded in under the template's name instead of being replaced by it; coverage is read for the first time at 44.29% overall / 26.07% for the library (PR #22)
- [x] Confirm the project builds under Swift 6 strict concurrency with no warnings — strict concurrency was already on and had been reporting five diagnostics into a build log nothing read; `xcodebuild` exits 0 with any number of warnings, so the claim had never been measured (PR #23)

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

Item 3 complete as of PR #22 (2026-08-03). There is one CI workflow now:
`.github/workflows/ci.yml`, all four checks green. "Promote" could not mean
"copy", because the template could never have run — it named a scheme that does
not exist (this is an SPM package; xcodebuild synthesises the names), hardcoded
`/Applications/Xcode_16.app`, pinned `OS=18.0` on the destination, and had a
lint step that printed "skipping" and exited 0 when swiftlint was absent. Item 2
had already solved all four for real, so `gates.yml` was folded in under the
template's name rather than replaced by it.

The one thing the template genuinely added was coverage.
`-enableCodeCoverage YES` had been passed to every test run since item 2 and
nothing ever read the result. It now reports **44.29% overall — and 26.07% for
`BoilerplateiOSSwift` itself**, the first time that number has existed. No
threshold is enforced: there was never one to lower, and a threshold invented
alongside the first measurement only fits whatever today happens to be. The
library figure is low enough to be worth its own item.

Two template steps were dropped rather than carried: the `.build` cache, which
cached nothing (`xcodebuild` builds into DerivedData), and the Codecov upload,
which had `fail_ci_if_error: false` and no token and so could only be
decorative. The template's `|| true` on the coverage read was deliberately not
preserved.

Simulator selection was also hardened, which was not planned work. The first run
sat several minutes in a step that took 43s on the last green run; the push that
followed superseded it, so whether it would have completed is unknown. Either
way the step was the only long one without a `timeout-minutes` backstop, so an
unresponsive CoreSimulator would have held the runner for the job's full hour and
then reported "cancelled" — naming no command and skipping the log upload that
would have. `simctl` is now bounded by perl's alarm and retried with a service
restart between attempts; dropping two redundant `simctl` calls took the step
from 43s to 4s. The retry wraps only the device-list query, so no failing build
or test can be retried into a pass.

Known gaps carried into item 4: the `--legacy` `xccov` fallback has never
executed, since the modern invocation worked. Coverage is reported, not gated.
`workflow-templates/testflight-deploy.yml` remains an unpromoted, never-executed
template. And CLAUDE.md's gate list still says `-scheme App`, which names nothing
in this package — the workflow comments record it, but the file itself is
uncorrected.

**Phase 0 complete as of PR #23 (2026-08-03).** All four items closed.

Item 4 was two claims, both unverified. Strict concurrency was genuinely on —
`-swift-version 6` is on the `swiftc` invocation in the run — but it rested on
one line of `Package.swift`, and nothing failed if that line were dropped,
downgraded to `.v5`, or overridden by a `SWIFT_VERSION` build setting on the
xcodebuild command line. Each target now carries a `#if !swift(>=6.0)` /
`#error` guard, so the language mode is a compile-time fact in the target it
protects. `#if swift(...)` tests the language mode; `#if compiler(...)` is the
one that reports the toolchain, and is the wrong check here.

"No warnings" had never been measured at all. `xcodebuild` exits 0 with any
number of them, so five had been accumulating in a ~5,000-line log that nothing
read. `.github/scripts/assert-no-warnings.py` now fails the job on any
`path:line:col: warning:` attributed to `Sources/` or `Tests/`, collapsing the
duplicates xcodebuild emits once per compilation unit, and runs between build
and test — it is a property of a compile that has already happened, so there is
nothing to gain by spending the simulator run first.

Three of the five were concurrency diagnostics. `CameraService.makeFrameStream`
had two `sessionQueue.async` bodies reading the enclosing `AsyncStream`
closure's `[weak self]` binding instead of capturing their own — a weak capture
is a mutable box, and two concurrently-executing closures were sharing one.
`DesignSystemTests.defaultStyleIsPrimary` set a captured `var` from a
`@Sendable` closure: `AppButton("Tap me") { ... }` resolves to the
`asyncAction:` initialiser, whose closure is `@escaping @Sendable () async ->
Void`. That flag was written and never read — the `_ = capturedAction // silence
warning` beneath it said so — and is gone; no assertion was lost. The other two
were an unused `withLock` result in `EventBus` and a `var` that is only read in
`AdaptiveLayoutTests`.

Scope of the gate, deliberately drawn: warnings from `GoogleSignIn-iOS` (checked
out into DerivedData, outside the workspace) and warnings carrying no source
location are printed, counted and grouped but do not fail the job. The first are
not this package's to fix and would hand a dependency a veto over every build
here; the second come from the build system rather than from compiling a source
file. Both stay visible in the log. `-warnings-as-errors` on the xcodebuild
command line was rejected because command-line build settings apply to every
target including dependencies, and `.unsafeFlags` in `Package.swift` because it
makes this package unusable as a dependency of any other.
`SwiftSetting.treatAllWarnings(as:)` is the tool that would replace this script,
and it needs swift-tools-version 6.2 — CI selects Xcode 16, which ships Swift
6.1.

Known gaps carried into Phase 1: the gate reads warnings only, so coverage is
still reported rather than enforced. `AppButton`'s action is never invoked by
any test — the `asyncAction:` initialiser wraps it in a detached `Task`, so
asserting it fires needs a deterministic handle on that Task, which is Phase 1
work rather than a warning fix. Everything item 3 recorded is still open: the
`--legacy` `xccov` fallback has still never executed,
`workflow-templates/testflight-deploy.yml` is still unpromoted, and CLAUDE.md's
gate list still says `-scheme App`, which names nothing in this package.

**Every gate in CLAUDE.md remains unrunnable in the scheduled agent's
environment.** It runs on Linux, where `swift`, `xcodebuild` and `swiftlint` do
not exist and Xcode cannot be installed. What was verified locally for this item
was the Python gate itself, against a synthetic xcodebuild log. The PR checks
are the source of truth for this repo, as items 1 and 2 also concluded.

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
- [x] Strict concurrency checking enabled with `Sendable` conformance across the codebase — checking was already on and gated from Phase 0 item 4; the conformances were not. Four test doubles asserted `@unchecked Sendable` over bare mutable stored properties, and `LoadingState` was not `Sendable` at any `Value` because its failure payload was a bare `any Error` (PR #24)
- [x] Actors for shared mutable state + a documented actor-reentrancy pitfall — `actor` buys isolation and is routinely misread as buying atomicity; `SingleFlightCache` is the memoising cache written from the two rules that misreading breaks, and the naive version is kept compiled and run so the pitfall is demonstrated rather than asserted (PR #25)
- [x] `@MainActor` isolation rules and safe hops off the main actor — the repo had followed "`@Observable`, `@MainActor` view models" since Phase 2 without ever saying how to leave the main actor or how to return to it; `Task { }` does not leave it, a `nonisolated` *synchronous* function does not either, and the `await` that does leave also releases it (PR #26)
- [ ] Structured concurrency: `TaskGroup`, cancellation propagation, and `withTaskCancellationHandler`
- [ ] `AsyncSequence`/`AsyncStream` wrapping a delegate-based API with backpressure notes
- [ ] Global actors and custom executors for a serial background domain
- [ ] Immutability: value semantics, `let`-first modelling, and copy-on-write inspection
- [ ] Async retry with exponential backoff and jitter, plus a timeout combinator

Item 3 complete as of PR #26 (2026-08-06). All four checks green; the test phase
runs in 197s.

Only a `nonisolated async` function changes where code runs, and the two
constructs reached for instead do not. `Task { }` marks its operation
`@_inheritActorContext`, so a closure literal written in a `@MainActor` method
runs its body on the main actor — it buys concurrency with respect to the caller
and none with respect to the main thread, which is exactly why it looks like it
worked. A `nonisolated` synchronous function moves nothing either: `nonisolated`
states what a declaration needs, not where it executes. `OffMainActor.run` is the
third case with a name, and the `@Sendable` on its parameter is load-bearing —
a non-`@Sendable` closure literal formed in a `@MainActor` method is inferred to
be main-actor-isolated, so without it the body returns to where it came from
while the signature claims otherwise.

`LatestOnlyTask` is the hop back. `hits = try await api.hits(matching: text)` has
no data race and compiles clean; it is still wrong, because responses do not
arrive in the order requests went out. It supersedes explicitly and then decides
by generation rather than by cancellation — cancellation is cooperative, so an
operation that swallows it finishes anyway and returns a perfectly good stale
result.

Two CI rounds were spent on real constraints, both recorded in the tests. First,
`Thread.isMainThread` is imported `NS_SWIFT_UNAVAILABLE_FROM_ASYNC`, so it cannot
be referenced from an `async` context at all; `CurrentThread.isMain` asks it from
a synchronous property, which has no suspension point for the answer to expire
across. Second, the suites saturated the cooperative pool: the
ignore-cancellation test spun on `await Task.yield()`, which is bounded in
wall-clock time and unbounded in scheduling pressure, and the test phase went to
559s with four pre-existing tests failing — `HomeViewModelConcurrencyTests` among
them, which `SendableConformanceTests` already records as the casualty of this
same failure mode. Both new suites are now `.serialized`.

**Carried forward: `SocialLoginViewModelXCTests` is flaky independently of this
work.** Run 30897280228, on `main` with none of PR #26's code present, failed
with `testClearErrorNilsErrorMessage()` exceeding the two-minute execution
allowance. Both tests that hang construct an `ASPresentationAnchor()` — a
`UIWindow` — while sibling tests doing the same pass in the same run. It is a
real defect and it will keep turning runs red at random until someone takes it.

**Every gate in CLAUDE.md remains unrunnable in the scheduled agent's
environment.** It runs on Linux, where `swift`, `xcodebuild` and `swiftlint` do
not exist. `assert-sendable-audit.py` is the only one that runs there, and it
did. The PR checks are the source of truth, as every item since Phase 0 item 1
has concluded.

Item 1 complete as of PR #24 (2026-08-04). All four checks green: `TEST BUILD
SUCCEEDED` with no warnings from this package's sources, 286 tests, SwiftLint
strict clean, and the new Sendable audit step passing.

Phase 0 item 4 had already made the Swift 6 language mode a compile-time fact and
gated the build at zero warnings, which is the "checking enabled" half. It is no
evidence about the other half, because `@unchecked Sendable` and
`nonisolated(unsafe)` are exactly the constructs that emit no diagnostic. Six
types opted out; four of them — `MockAPIClient`, `MockBiometricAuthService`,
`MockSocialAuthProvider`, `MockSocialAuthExchangeService` — asserted the
conformance over bare mutable stored properties with no synchronisation at all,
which is a data race the checker had been told not to look at, reachable from any
test that configures a double on one task and exercises it from another. All four
now hold state inside `OSAllocatedUnfairLock`, the pattern `MockAuthService`
already used here; `EventBus`, `InMemoryKeychain` and `AtomicCounter` had the
correct-but-unverifiable lock-beside-a-`var` shape and were converted too. The
property APIs did not change, so no test call site moved.

`LoadingState` was the one value type that was not `Sendable` at all:
`case failure(Error)` stores a bare existential, which does not conform, so no
`LoadingState` was `Sendable` whatever its `Value`. It had zero call sites, which
is the only reason nobody had hit it.

Two opt-outs remain and are load-bearing, both AVFoundation's shape rather than
ours: `CapturedFrame` wraps a `CMSampleBuffer`, and `CameraService` is isolated
by a serial `DispatchQueue` the compiler cannot see.

Two gates keep it from rotting. `.github/scripts/assert-sendable-audit.py` fails
on any opt-out not recorded with a reason **and** on any recorded reason whose
code is gone; it is syntactic, so it is the one gate in this repo that runs on
the Linux agent. `SendableConformanceTests` names the 67 types whose conformance
is load-bearing and requires it as a generic constraint — most are inferred and
appear nowhere in the source, so without it losing one is silent until a distant
call site fails. `docs/concurrency.md` documents the isolation model.

One red run on the way, worth recording because the cause was not where it
looked. `HomeViewModelConcurrencyTests.startLiveUpdatesAppendsItems` failed while
the build was clean. Nothing in the PR touches `HomeViewModel`: Swift Testing runs
suites in parallel, and the new coherence test fanned out to 200 concurrent tasks
in one group and saturated the cooperative pool. The tell was the timing — that
suite's four tests sleep about 0.7s in total and it took 40.462s before failing.
Reshaped to 8 tasks looping 25 times each, same call count and same assertions.
**Wall-clock tests in this suite are the canary for pool pressure; keep new task
groups narrow.**

Known gaps carried into item 2: the audit lists types by hand, so a new model
nobody adds to it is unaudited. Coverage is still reported rather than gated and
the `--legacy` `xccov` fallback has still never executed;
`workflow-templates/testflight-deploy.yml` is still unpromoted; and CLAUDE.md's
gate list still says `-scheme App`, which names nothing in this package.

Item 2 complete as of PR #25 (2026-08-05). All four checks green on the first
run: `TEST EXECUTE SUCCEEDED`, 296 tests, SwiftLint strict clean, the Sendable
audit unchanged at 2 recorded opt-outs, and line coverage up from 44.29% to
46.86% (library 26.07% → 27.72%).

The item's substance is the pitfall, not the actor. `actor` buys **isolation**;
it is routinely misread as buying **atomicity**, which is a different property it
does not provide. An actor is mutually exclusive only *between* suspension
points, so a check-then-act sequence split by an `await` is not atomic and state
read before the suspension may be stale after it. The canonical casualty is the
memoising cache: N concurrent callers on a cold key all pass the emptiness check
before any of them writes back, and the expensive load runs N times. None of that
is a data race — it compiles clean under Swift 6 strict concurrency, which is
exactly why the Phase 0 item 4 warning gate and the item 1 Sendable audit have
nothing to say about it, and why this item asks for documentation rather than
another checker.

`SingleFlightCache` is that cache written from the two rules the pitfall implies.
It publishes the in-flight `Task` into its entry table in the same uninterrupted
stretch of actor execution as the lookup that found the key empty, so a second
caller either starts the load or finds a task to await with no third possibility;
and on completion it re-reads the slot and writes only if it still holds its own
task, so a load invalidated mid-flight cannot resurrect the entry a caller just
dropped. Failures are not cached. `TokenStore.refreshIfNeeded` already had the
first half of this shape for concurrent 401s; this generalises it and names the
reasoning behind it.

The pitfall is demonstrated, not asserted: `NaiveCache` in
`SingleFlightCacheTests` is the wrong version, compiled and run, with a test
asserting the five duplicate loads five concurrent callers produce. A pitfall
nothing executes is folklore, and folklore stops being true without telling you.
`docs/concurrency.md` carries the same reasoning under "Actors give you
isolation, not atomicity".

Known gaps carried into item 3: `SingleFlightCache` is a utility beside
`EventBus` and `PollingStream` — no feature is migrated onto it, so the avatar
and image paths still load per-caller. The coalescing and mid-flight-invalidation
tests are timing-based (a load that sleeps 80-200ms while callers pile in) rather
than gated on an explicit signal, which is reliable at this width but is the
shape item 1 found can be starved by pool pressure; keep new task groups narrow.
Every gap item 1 recorded is still open — the audit is still hand-maintained,
coverage is still reported rather than gated, `testflight-deploy.yml` is still
unpromoted, and CLAUDE.md still names `-scheme App`.

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
