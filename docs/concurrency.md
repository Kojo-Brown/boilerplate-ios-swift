# Concurrency and `Sendable`

How this package decides what is safe to send across an isolation boundary, and
what stops that decision from rotting.

## The language mode is a compile-time fact

`Package.swift` sets `.swiftLanguageMode(.v6)` on both targets, so `Sendable`
checking is on and errors are errors rather than warnings.

That setting alone was not enough to *claim* strict concurrency, because nothing
failed if it were dropped, downgraded to `.v5`, or overridden by a `SWIFT_VERSION`
build setting on an `xcodebuild` command line. Each target therefore carries a
guard in `LanguageMode.swift`:

```swift
#if !swift(>=6.0)
#error("...")
#endif
```

`#if swift(...)` tests the *language mode*. `#if compiler(...)` reports the
toolchain, which is the wrong question — a Swift 6 compiler will happily build a
target in Swift 5 mode.

## Four ways to be `Sendable`, in order of preference

**1. Be a value type.** Structs and enums of `Sendable` members are `Sendable`,
inferred, with nothing to maintain. The wire models, the domain models, the
endpoint description, and every error type are all this. `CLAUDE.md`'s "value
types by default" is the concurrency rule as much as the style one.

**2. Be isolated to an actor.** `TokenStore` is an `actor` because it owns
mutable token state that several tasks reach for at once. Global-actor isolation
counts too: a `@MainActor final class` is implicitly `Sendable`, which is what
makes the `@Observable` view models, `AppCoordinator`, `AppState`, and the
SwiftData-backed persistence services safe to hold from anywhere. `ModelContext`
is not `Sendable`, so `SwiftDataUserPersistenceService` is `@MainActor` and its
methods are `async` — callers off the main actor hop, rather than the context
travelling.

**3. Hold mutable state inside a lock, not beside one.** For a type that must be
a class, must be mutable, and must not be actor-isolated — most test doubles, and
`EventBus` — the state goes *inside* `OSAllocatedUnfairLock`:

```swift
private struct State: Sendable {
    var handler: Handler = { _ in EmptyResponse() }
}
private let state = OSAllocatedUnfairLock(initialState: State())

var handler: Handler {
    get { state.withLock { $0.handler } }
    set { state.withLock { $0.handler = newValue } }
}
```

The distinction is the whole point. A `private var` guarded by an `NSLock` beside
it is just as correct at runtime, but the compiler cannot see the relationship,
so that shape needs `@unchecked Sendable`. Moving the state inside the lock
leaves the class holding only `let` properties of `Sendable` type, which the
compiler checks by itself — and keeps checking after the next edit.

`OSAllocatedUnfairLock` is iOS 16+, so it fits this package's iOS 17 floor.
`Synchronization.Mutex` is the better tool and is iOS 18, so it is not available
here yet.

Two rules for using it:

- **Never hold the lock across `await`.** `os_unfair_lock` is owned by the thread
  that took it, and a task resumed after a suspension may be on a different one.
  Read what you need out of the lock, then await. `MockAPIClient.send` and the
  social-auth doubles both snapshot first for this reason.
- **Never call out while holding it.** `EventBus.emit` copies the continuations
  under the lock and yields outside it, so a subscriber that re-enters `emit`
  meets an unlocked bus instead of a deadlocked one.

**4. `@unchecked Sendable`, only where the other three are impossible.** This is
an assertion, not a check: the compiler records it and stops looking, including
at whatever gets added to the type later.

## The two remaining opt-outs

Both are in `CameraService.swift`, both are AVFoundation's shape rather than
ours, and both are recorded in `.github/scripts/assert-sendable-audit.py` with
the reason:

| Type | Why it cannot be checked |
| --- | --- |
| `CapturedFrame` | Wraps `CMSampleBuffer`. CoreMedia's types carry no `Sendable` annotation and are not ours to annotate. The wrapper narrows the assertion to the single hop the frame really takes: capture queue to recogniser, never mutated after capture, not retained past the `recognise` call that consumes it. |
| `CameraService` | Holds `AVCaptureSession` and the stream continuation, both confined to `sessionQueue`. The isolation is a serial `DispatchQueue` rather than an actor because `AVCaptureVideoDataOutputSampleBufferDelegate` delivers on a queue you hand it, and the compiler cannot see that a queue guards a property. |

`UserEntity` is deliberately absent from the audit and carries no opt-out: it is
a SwiftData `@Model` class, is not `Sendable`, and is not meant to be. It never
leaves the main actor — `UserPersistenceService` maps it to the `Sendable`
`User` struct at the boundary, which is the pattern to copy for any future
`@Model` type.

## What enforces all of this

Three gates, none of which depend on anyone remembering the rules:

- **`.github/scripts/assert-sendable-audit.py`** (CI: *SwiftLint (strict)* job).
  Finds every `@unchecked Sendable` and `nonisolated(unsafe)` under `Sources/`
  and `Tests/` and fails on any that is not in its table with a reason. It fails
  in the other direction too: an entry whose code is gone is a stale suppression,
  and stale suppressions are how an allowlist becomes a rubber stamp. It is
  syntactic, so it runs without a toolchain — including on the Linux agent that
  cannot run any of the other gates.
- **`Tests/ViewModelTests/SendableConformanceTests.swift`**. Names every type
  whose `Sendable` conformance is load-bearing and requires it as a generic
  constraint. Most of these conformances are inferred and appear nowhere in the
  source; without the audit, losing one is silent until some distant call site
  fails to compile. With it, the error lands here.
- **`.github/scripts/assert-no-warnings.py`**. Fails the build on any warning
  from this package's own sources, so a concurrency diagnostic cannot accumulate
  in a log nobody reads. That is how the five that had been doing exactly that
  were found.

## `LoadingState`, and why the payload is not `any Error`

`LoadingState.failure` carries `any Error & Sendable`. The bare `any Error`
existential is not `Sendable`, so `case failure(Error)` made every
`LoadingState` non-`Sendable` whatever its `Value` was — an
`AsyncStream<LoadingState<User>>` would not have compiled. Nothing had reached
for one yet, which is the only reason it went unnoticed; the type had no call
sites at all.

The conformance is conditional (`extension LoadingState: Sendable where Value:
Sendable`) so the type stays usable with a non-`Sendable` `Value` that never
leaves the main actor.

A `catch` block binds `error` as `any Error`, which no longer satisfies the
payload. Errors thrown across an isolation boundary have to be `Sendable`
anyway, so the fix at such a site is to name the concrete error type —
`catch let error as APIError` — not to widen the payload back.
