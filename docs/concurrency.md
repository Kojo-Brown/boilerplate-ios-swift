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

## Actors give you isolation, not atomicity

Making shared mutable state an `actor` removes the lock and the data race. It
does not make a method body atomic, and reading it as though it does is the most
common way to write a correct-by-the-compiler actor that still does the wrong
thing.

An actor guarantees mutual exclusion only *between* suspension points. At every
`await` inside an isolated method the actor is released, another call can run to
completion, and the first one resumes into whatever state that left behind. This
is reentrancy. It is deliberate — without it, an actor awaiting the network would
block every other caller — and it means an `await` is a hole in any invariant the
method is maintaining across it.

The check-then-await-then-act cache is the canonical way to fall in:

```swift
actor NaiveCache {
    private var cached: [Key: Value] = [:]

    func value(for key: Key) async throws -> Value {
        if let hit = cached[key] { return hit }   // 1. check
        let value = try await load(key)           // 2. suspend — actor released
        cached[key] = value                       // 3. act
        return value
    }
}
```

Five callers arriving on a cold key all get past step 1 before any reaches step
3, so the load runs five times. That actor is not a hypothetical in this repo:
it is compiled and run in `SingleFlightCacheTests`, where the test asserts the
five duplicate loads. A pitfall nothing executes is folklore, and folklore stops
being true without telling you.

`SingleFlightCache` is the same cache written from the two rules that follow:

- **Publish in-flight work before the first `await`.** It creates the loading
  `Task` and stores it in the same uninterrupted stretch of actor execution as
  the lookup that found the key empty. A second caller either arrives before that
  write and starts the load, or arrives after it and finds a task to await; there
  is no third possibility, which is the guarantee steps 1-to-3 lacked.
- **Re-read shared state after an `await`.** When the load returns, the entry
  holds whatever it holds *now* — `invalidate(_:)` may have run in the meantime.
  Writing the result back unconditionally would resurrect an entry a caller had
  explicitly dropped, with the stale value it was dropped for. The completion
  path compares task identity and writes only if its own claim is still there.

The same shape is already in `TokenStore.refreshIfNeeded`, which stores the
in-flight refresh `Task` before awaiting it so that concurrent 401s produce one
refresh request rather than one per caller.

Two rules of thumb fall out. Prefer synchronous actor methods where the work
allows it — a method with no `await` in it *is* atomic, and needs none of this.
Where a suspension is unavoidable, hold no invariant across it: park a value the
other callers can find, and re-check before acting on anything read beforehand.

## `@MainActor`: leaving it, and coming back

`@MainActor` is a global actor and obeys every rule above, including reentrancy.
It gets treated as a different kind of thing — a thread you are on rather than an
actor you hold — and that is where its two characteristic bugs come from.

### Only a `nonisolated async` function changes where code runs

Three constructs are reached for to move work off the main thread. One of them
works, and it is not the popular one.

| Written inside a `@MainActor` method | Where the body runs |
| --- | --- |
| `Task { … }` | **On the main actor.** `Task.init` marks its operation `@_inheritActorContext`, so a closure literal inherits the enclosing isolation. |
| `nonisolated func` (synchronous) | **On the main actor.** `nonisolated` says the declaration does not need the isolation; it does not say where it executes, and a synchronous call is a jump, not a scheduling decision. |
| `nonisolated func … async` | **On the cooperative pool.** Since SE-0338 a nonisolated async function runs on the generic executor rather than inheriting its caller's actor. |

`Task { }` is the one that bites, because it *is* concurrency — the enclosing
method returns without waiting — so it looks like it worked. It buys concurrency
with respect to the caller and none with respect to the main thread. A 200 ms
parse inside one is still 200 ms of dropped frames, now at an unpredictable
moment.

`OffMainActor.run` is the third row with a name:

```swift
let report = await OffMainActor.run { Report.parse(payload) }
```

The `@Sendable` on its parameter is load-bearing rather than descriptive. A
non-`@Sendable` closure literal formed in a `@MainActor` method is *inferred* to
be `@MainActor`-isolated, and passing one would put the body back on the main
actor while the signature claimed otherwise. `@Sendable` closures do not inherit
isolation, so the annotation is what makes the hop real.

Because it never leaves the caller's task, it inherits that task's priority,
task-local values and cancellation. `Task.detached { }` also leaves the main
actor and inherits none of the three, so cancelling the caller leaves the work
running — save it for work that genuinely has to outlive whatever started it.
`OffMainActor.run` is a hop, not a fork: the caller is suspended for its
duration. When two things really should happen at once, that is `async let` or a
task group.

`MainActor.assumeIsolated` is the trip in the other direction and is not a hop at
all. It asserts that this synchronous code is *already* on the main actor and
hands over the isolation, trapping if the assertion is false. That is the right
tool for a framework callback documented to arrive on the main thread —
`AppleSignInService`'s `ASAuthorizationControllerDelegate` methods are all
`nonisolated` and use it. `MainActor.run` cannot serve there: it is `async`, a
synchronous callback has nowhere to put the `await`, and deferring the write past
the callback's own return is exactly the ordering the delegate contract rules
out.

### The `await` that left also released the main actor

The hop back is the half that gets forgotten. Suspending released the main
actor, so other main-actor work ran while this was away — very often a second
call to the same method. State read before the hop may be stale after it, and
`MainActorIsolationTests` demonstrates that on the main actor rather than
asserting it.

Written the obvious way, this is wrong:

```swift
func queryChanged(_ text: String) async {
    hits = try await api.hits(matching: text)   // ← whoever finishes last wins
}
```

There is no data race and Swift 6 compiles it without complaint: the assignment
happens on the main actor and no invariant visibly spans the `await`. The defect
is ordering. Responses do not arrive in the order the requests went out, so
typing `sw` then `swift` leaves the list showing results for `sw` whenever the
shorter query is slower — a stale screen with a healthy network log, which is why
it ships.

`LatestOnlyTask` is that method written from the two rules that fix it:

- **Supersede explicitly.** A new run cancels the one in flight rather than
  racing it.
- **Decide by generation, not by cancellation.** Each run takes a ticket before
  it suspends and re-reads the counter when it resumes; only the holder of the
  current ticket may deliver. Cancellation is cooperative, so it is a request,
  not a guarantee — an operation that never checks for it runs to completion and
  produces a perfectly good stale result. `LatestOnlyTaskTests` runs that exact
  path against an operation written to ignore cancellation outright.

Two calls can be inside `run` at once precisely because the first one's `await`
released the main actor. The type is built on main-actor reentrancy rather than
defending against it: the ticket is claimed, the old run cancelled and the new
task published in one unsuspended stretch, which is the same discipline
`SingleFlightCache` uses to make its lookup atomic.

## Structured concurrency: the scope is the guarantee

A task group and a `for` loop full of `Task { }` look alike and differ in the
only property that matters. The group is *structured*: no child of it can
outlive the call that created it. `withThrowingTaskGroup` does not return until
every child has finished, on all three exits — the results were drained, a child
threw and the rest were cancelled and awaited, or the caller was cancelled and
the group drained what was left. The loop of `Task { }` returns immediately with
the work still running, cancels nothing when the caller is cancelled, and
reports no error to anybody.

`ConcurrentMap.over(_:maxConcurrent:transform:)` is the everyday use of a group,
written from the three things a hand-rolled one usually gets wrong.

**A group is not a queue.** `addTask` does not enqueue work for the group to
pace; it creates a child that is immediately runnable. `for url in urls {
group.addTask { … } }` over 500 URLs opens 500 sockets. The cooperative pool is
sized to the core count, but that bounds how many children are *executing*, not
how many are suspended on a socket each holding a buffer — so this reads as a
server refusing connections, or a memory ceiling on an older device, under a
load the simulator never produced. The fix needs no semaphore: prime the group
with `maxConcurrent` children and add exactly one more each time `next()` hands
back a result. The group's own `next()` is the backpressure.

**`next()` yields in completion order.** Collecting with `results.append(value)`
scrambles the input order, invisibly whenever the transform is uniformly fast.
It surfaces in production on the slow network, as a list whose rows are
shuffled, and under test only if the fixtures have deliberately uneven timing —
which fixtures rarely do. Each child here carries the offset it came from and
writes to that slot, so ordering is a property of the code rather than of how
the race happened to run. `ConcurrentMapTests` drives both spellings through
identical gates, with the completion order chosen by the test rather than raced,
and gets `["a", "b", "c", "d"]` from one and `["d", "c", "b", "a"]` from the
other.

**Cancellation has to stop the *feeding*, not just the children.** Children are
cancelled for you when the parent is. Refilling the window is not: `addTask`
would happily add child six to a cancelled group, where it is born cancelled and
— if its transform never checks `Task.isCancelled` — runs to completion anyway.
`addTaskUnlessCancelled` is what declines to start it, and it is the only thing
that can. The test cancels a run of six with a window of two and asserts that
exactly two ever started.

That last point generalises: **cancellation is a request, and a child decides
what to do with it.** A child that catches `CancellationError` and returns a
value has produced a result, and `over` returns it. Work that finished before
the cancellation landed is not discarded — cancelling is a request to stop, not
an instruction to throw away what is already paid for. What the caller is not
allowed to get is a half-filled array reported as success, so a run left with
holes throws `CancellationError` rather than returning fewer results than it was
given inputs.

## `withTaskCancellationHandler`: cancelling work that is not Swift's

Cooperative cancellation is delivered at suspension points. A continuation
bridging a callback API has none to deliver it to — the task is parked on a
callback, and nothing about `Task.isCancelled` becoming true reaches the thing
that will eventually call it:

```swift
try await withCheckedThrowingContinuation { continuation in
    legacyAPI.start { continuation.resume(with: $0) }   // ← nothing can stop this
}
```

Cancelling the surrounding task sets a flag and the task stays suspended until
the callback arrives on its own schedule. A screen dismissed mid-scan keeps the
camera running; a search superseded three keystrokes ago keeps its socket open.
This package has six bridges of exactly that shape — in `TextRecognitionService`,
`CameraService`, `BarcodeScannerService`, `GoogleSignInService` and
`AppleSignInService` — and none of them can be cancelled. That is not an
oversight in any one of them; it is what a bare continuation is.

`withTaskCancellationHandler` is the only way to be *told*, and telling the
underlying API is the only way to stop. `CancellableContinuation.run` is that
pairing written once:

```swift
try await CancellableContinuation.run { finish in
    let task = URLSession.shared.dataTask(with: request) { data, _, error in
        finish(Result { … })
    }
    task.resume()
    return { task.cancel() }        // ← how this particular API is stopped
}
```

### Why it needs a lock and not a flag

`onCancel` is not scheduled. It runs **synchronously, on whichever thread called
`cancel()`**, concurrently with the operation body, and at any point relative to
it — including before the body has started, since a task already cancelled when
it reaches the handler has the handler invoked immediately. Three interleavings
follow, and each is a hang or a trap if the state is a plain `var`:

| Cancel arrives… | What must happen |
| --- | --- |
| before the continuation exists | `onCancel` has nothing to resume, so the body must notice on arrival and resume itself. Miss it and the task hangs forever — nothing calls the handler twice. |
| while `start` is still running | The cancel handle does not exist yet, so `onCancel` cannot use it. Whoever receives it must check on receipt whether it is already stale, or the work runs on with nobody waiting for it. |
| just as the callback fires | Both paths reach for the same continuation. Resuming one twice does not produce a wrong answer, it traps — which is the whole reason to pay for `CheckedContinuation` in a bridge rather than the unsafe one. |

So exactly one of the three paths wins, decided under a lock, and the losers do
nothing. The state lives *inside* `OSAllocatedUnfairLock` per the rule above, so
the bridge needs no `@unchecked Sendable`; neither critical section awaits or
calls out while holding it, so a resume never happens under a non-recursive
lock.

`CancellableContinuationTests` drives all three moments rather than racing them:
it holds the callback the bridge handed out and fires it at the awkward instant
on purpose. The late-callback test is the one that would crash the test process
against a bridge that had kept the continuation — a race a sleep-based test
would reproduce perhaps one run in fifty.

One deliberate choice: on cancellation this resumes with `CancellationError`
straight away rather than waiting for the API to acknowledge, and drops whatever
the callback reports afterwards. Cancellation is cooperative, so an API that
never calls back after being cancelled is ordinary rather than broken, and a
bridge that waited for it would turn that into a permanently suspended task.

## What enforces all of this

Six gates, none of which depend on anyone remembering the rules:

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
- **`Tests/ViewModelTests/MainActorIsolationTests.swift`**. Measures where code
  actually runs, for each row of the table above, plus the reentrancy of the main
  actor across an `await`. Two of those answers are the opposite of what the
  syntax suggests, and all of them are version-sensitive — SE-0338 settled the
  execution semantics of nonisolated async functions in Swift 5.7, and Swift
  6.2's `nonisolated(nonsending)` moves the default again for anyone adopting it.
  If a toolchain upgrade changes where a hop lands, this suite is what says so.
  The probe is `CurrentThread.isMain` rather than `Thread.isMainThread` directly:
  Foundation imports the latter as unavailable from asynchronous contexts, on the
  grounds that in an `async` function the answer expires at every suspension
  point. Reading it through a synchronous property is the sanctioned way round
  that, and a synchronous body has no suspension point for the answer to expire
  across.
- **`Tests/ViewModelTests/ConcurrentMapTests.swift`**. Measures the peak
  concurrency and the result ordering of `ConcurrentMap.over` and of the
  unbounded, completion-ordered spelling it replaces — the naive one is compiled
  and run, not quoted, for the same reason `SingleFlightCacheTests` keeps its
  naive actor. It also asserts the structural guarantee directly: after the call
  throws, nothing it started is still in flight.
- **`Tests/ViewModelTests/CancellableContinuationTests.swift`**. Drives each of
  the three cancellation interleavings by holding the bridged API's callback and
  firing it at the awkward moment, rather than sleeping and hoping. Two of them
  trap the process against a bridge that got them wrong, so a regression here
  fails loudly rather than intermittently.
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
