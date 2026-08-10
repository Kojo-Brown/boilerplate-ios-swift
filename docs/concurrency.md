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

## The three remaining opt-outs

Two are in `CameraService.swift` and are AVFoundation's shape rather than ours.
The third is the one place this package builds a value type over a mutable
allocation by hand. All three are recorded in
`.github/scripts/assert-sendable-audit.py` with the reason:

| Type | Why it cannot be checked |
| --- | --- |
| `CapturedFrame` | Wraps `CMSampleBuffer`. CoreMedia's types carry no `Sendable` annotation and are not ours to annotate. The wrapper narrows the assertion to the single hop the frame really takes: capture queue to recogniser, never mutated after capture, not retained past the `recognise` call that consumes it. |
| `CameraService` | Holds `AVCaptureSession` and the stream continuation, both confined to `sessionQueue`. The isolation is a serial `DispatchQueue` rather than an actor because `AVCaptureVideoDataOutputSampleBufferDelegate` delivers on a queue you hand it, and the compiler cannot see that a queue guards a property. |
| `CopyOnWriteBox` | Its `Storage` class holds a mutable `var` and is not `Sendable`; the struct in front of it is, conditionally on `Value`, because copying is what sending a struct means and every mutation of a *shared* allocation copies rather than writing through it. The unprovable part is that `Storage` never escapes and that every write funnels through `makeUnique()` — true of one file, which is why `Storage` is private to it. `Array` makes the same bargain for the same reason. See [Value semantics](#value-semantics-let-first-modelling-and-copy-on-write). |

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

## `AsyncStream` over a delegate: the backpressure that isn't there

`CameraService` turns an `AVCaptureVideoDataOutputSampleBufferDelegate` into an
`AsyncStream<CapturedFrame>`, which is the standard move and reads like a
translation between two equivalent things. It is not one. A delegate callback
and an async sequence disagree about who waits, and the bridge is where that
disagreement gets settled — silently, if nobody settles it deliberately.

Backpressure is a consumer telling a producer to slow down, and it needs a
producer that can be told. `AsyncStream` has the channel for it: `yield` returns
a `YieldResult` carrying the space left in the buffer. `captureOutput` cannot
act on it. It is a synchronous method AVFoundation calls on a queue of its own,
it cannot `await`, and a bridge that blocked inside it would block the capture
queue — starving the preview layer and the session's own bookkeeping to protect
a recogniser. So the producer runs at 30 fps whatever happens, the consumer runs
at whatever a Vision request costs, and the difference has to go somewhere.

There are two somewheres: memory, or the floor. That is the whole of the choice,
and `AsyncStream` makes it for you if you let it — the default is `.unbounded`,
which is memory, forever.

### Bridging disarms the drop policy that was already there

`AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames` is a drop policy, it is
set in `configureSession`, and it looks like the answer. It drops a frame when
the delegate is *still executing* the previous one. Once the delegate body is
`yield(…)` and nothing else, that never happens: a yield returns in nanoseconds
whatever the consumer is doing, so AVFoundation sees a delegate that is never
late and hands over every frame there is. Bridging to a stream moves the queue
from a place with a bound to a place without one, and it does so by making the
old bound stop firing rather than by removing it — so nothing reports it.

The cost is specific. `AVCaptureVideoDataOutput` vends sample buffers from a
pool of fixed size, and a buffer goes back to the pool when the last reference
to it goes away. An unbounded stream holds a reference to every frame the
consumer has not reached, so a consumer slower than the capture rate drains the
pool, and an output with no free buffers stops delivering. What that looks like
is not a memory graph climbing: it is scanning that quietly stops working while
the preview — fed by its own connection to the session — keeps moving.

### The policy is a domain decision, so it is a parameter

`DelegateStream` has no default `bufferingPolicy`. Picking one is the point:

- **`.bufferingNewest(1)`** for a live signal where only the latest sample means
  anything — video frames, location fixes, the position of a drag. The consumer
  never works on stale input, the producer never waits, and the backlog cannot
  exist. This is what `CameraService` uses.
- **`.bufferingOldest(n)`** where the first elements are the ones that matter
  and a burst past `n` is a fault to report rather than absorb — a handshake
  sequence, the opening errors of a storm.
- **`.unbounded`** only where something else already bounds the producer: a
  finite document, a paged fetch, a callback the code itself drives. It is not a
  default. It is a claim that no burst is possible.

`DelegateStreamTests` runs the same slow consumer against two of these and gets
different answers from each. Under `.bufferingNewest(1)` it is handed frame 30
while the camera is at 30; under `.unbounded` it is handed frame 2, with 28 more
queued behind it, each still holding its buffer. Neither run has a sleep in it —
a synchronous producer yielding into a stream nobody is draining fills the
buffer deterministically, and the consumer is stepped one element at a time
through the iterator.

Whichever policy is chosen, it discards without saying so, which is why
`statistics` counts. A scan that never completes looks identical from the view
model whether the recogniser is wrong or the frames never arrived.

### One consumer, and the bug that superseding hides

An `AsyncStream` is not multicast: two tasks iterating one stream split the
elements between them rather than each seeing all of them. So `DelegateStream`
vends one live stream at a time, and a second `makeStream()` supersedes the
first — finishing it, so its consumer's `for await` *ends* rather than waiting
forever on a stream nothing will yield to again.

Superseding is why the continuation is tracked by generation rather than held in
a plain property. A replaced stream's termination handler still runs, and the
obvious body for it is "clear the stored continuation" — which clears the *live*
one, installed by the call that did the replacing. `CameraService` had exactly
that shape, and both view models call `makeFrameStream()` on every
`startScanning()`, so the path was reachable from the ordinary sequence of stop,
start, stop. The generation is what lets a late handler recognise that it is
reporting a stream nobody is listening to any more, and do nothing.

The same distinction decides what a termination handler is told. Being
superseded is not reported: the producer has not become unwanted, somebody else
wants it, and a camera torn down there would race the consumer that just asked
for it. `CameraService` installs no handler at all for that reason — the session
outlives any one consumer and is shared with `previewLayer`, and the view models
cancel the frame task as a way of switching streams. `stop()` ends the session,
and it stays the caller's to call.

## A global actor, and the executor underneath it

`DiagnosticsActor` is this package's one global actor. It exists for a domain
that needs three things at once: several types sharing one isolation domain, a
thread that is allowed to block, and a fixed QoS that does not follow the
caller's priority.

### A global actor is for a domain, not for a type

A plain `actor` gives *one instance* its own isolation. That is the right
default, and `TokenStore` is it — token state, protected, nothing else inside.

The default stops fitting when two types have to agree about each other's state.
`DiagnosticJournal` admits a record only if `DiagnosticBudget` has room, which is
a check followed by an act. As two actors, the check is an `await`, and every
`await` is a hole: a second caller can be admitted against a count the first one
has already decided to change. That is the same non-atomicity
`SingleFlightCache` exists to close, reintroduced by nothing more than a choice
of isolation. As one global actor, `record` consults the budget with a plain
synchronous call and there is no suspension point for anything to run in.

So the question is not "does this need an actor" but "how many things belong in
this domain". One: `actor`. Several: `@globalActor`.

The price is that a global actor is global state. Every `@DiagnosticsActor`
declaration shares one queue, so a slow write in any of them delays all of them,
and there is no second, independent diagnostics domain to be had — not even for
a test. `DiagnosticJournal` takes its sink and budget as initialiser parameters
for exactly that reason: the domain is global, the objects in it are not, and
the tests build their own.

### Neither executor promises an ordering

The reflex is that a serial domain gives ordered delivery. It does not. Nothing
orders two *independently created* tasks arriving at the same actor: the default
actor executor drains its queue in priority order, and while a serial
`DispatchQueue` is FIFO with respect to `enqueue`, when each task gets to call
`enqueue` is still a scheduling detail.

A total order has to be taken *inside* the domain, where the actor's own
serialisation supplies it. `DiagnosticJournal.record` stamps its sequence number
there, in a method with no `await` in it, which is why sixty-four concurrent
callers produce sixty-four consecutive numbers.

The same reasoning is why there is no `DiagnosticJournal.log(_:)` that wraps the
hop in a `Task` and returns immediately. It would be the nicer API and it would
lose the property a log exists to have: two calls in a row from one function are
two independent tasks, and the second line can be journalled before the first.
`record` is awaited, so the caller's own program order survives.

### What the custom executor is actually for

`SerialDispatchExecutor` is installed by overriding `unownedExecutor`:

```swift
@globalActor
actor DiagnosticsActor {
    static let shared = DiagnosticsActor()
    nonisolated let executor = SerialDispatchExecutor(label: "…diagnostics", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }
}
```

Both `nonisolated`s are load-bearing. The runtime reads `unownedExecutor` in
order to schedule work *onto* this actor, which is necessarily from outside the
actor's isolation — an executor you had to be isolated to reach would be
unreachable, because reaching it is how you become isolated. Leaving the stored
property to the compiler's implicit "a `Sendable` `let` is nonisolated" rule is
not enough: read it from a `@DiagnosticsActor` context and you get *"actor-
isolated property 'executor' can not be referenced from global actor
'DiagnosticsActor'"*, because isolation to the global actor is not the same
statement as isolation to the `DiagnosticsActor.shared` instance. Nothing is
given up by saying `nonisolated` outright — the value is an immutable reference
to a `Sendable` type, so there is no state for the isolation to have guarded.

It buys none of the things it is usually reached for. It does not make the actor
serial — every actor already is. It does not order anything, per above.

What it buys is a thread that is not the cooperative pool's. The pool has one
thread per core and no reserve, on the stated assumption that work there
*suspends* rather than *blocks*. `FileDiagnosticSink.write` is a `write(2)`; it
blocks. On the pool that parks one of a handful of threads inside a syscall and
stalls unrelated tasks across the process, so a domain whose terminal operation
is blocking I/O has to run somewhere it is allowed to block. A serial
`DispatchQueue` is that somewhere, and the cost of blocking it is bounded to the
domain that chose to.

Two smaller reasons come with it. The queue label appears in crash reports,
`sample`, and Instruments, so this work is attributable instead of being another
anonymous `com.apple.root.*` frame. And jobs run at the queue's QoS whatever the
enqueuing task's priority, so a background domain called from a `.userInitiated`
task cannot inherit its way into competing with it. Dispatch may still boost the
queue to resolve a priority inversion, which is the intended behaviour rather
than a hole in the ceiling.

### `enqueue`, and why the job is converted

```swift
func enqueue(_ job: consuming ExecutorJob) {
    let unownedJob = UnownedJob(job)
    queue.async { [self] in
        unownedJob.runSynchronously(on: asUnownedSerialExecutor())
    }
}
```

The conversion is required, not stylistic. `ExecutorJob` is non-copyable and
non-`Sendable`, so it cannot be captured by the escaping closure `async` takes;
`UnownedJob` is the unmanaged handle that can be. Consuming the `ExecutorJob` to
make one transfers an obligation to run it exactly once — drop the handle
without running it and the job leaks and whatever awaits it hangs.

`UnownedSerialExecutor` does not retain, which is why the actor holds the
executor as a stored `let`: something has to own it, and an executor that
outlives nothing is an executor the runtime has a dangling reference to.

### `checkIsolated()` is not optional

```swift
func checkIsolated() {
    dispatchPrecondition(condition: .onQueue(queue))
}
```

This is SE-0424's hook. `assumeIsolated` and `assertIsolated` cannot reason
about a custom executor by themselves, so they ask it, and the protocol's
default implementation traps unconditionally with "expected checkIsolated to be
implemented" — which turns every `assumeIsolated` on the domain into a crash,
including the correct ones. Implementing it is also what makes the
`DispatchQueue` backing worth having for interop: a legacy callback delivered to
that queue really is isolated to the actor, and this is how the runtime can be
told to verify that rather than take it on trust.

It carries no availability annotation. The requirement it satisfies is gated to
the Swift 6 runtime, a witness may always be *more* available than its
requirement, and leaving it ungated is what lets the tests call it directly on
the package's iOS 17 floor.

## Value semantics, `let`-first modelling, and copy-on-write

Rule 1 of "four ways to be `Sendable`" is *be a value type*, and it is the only
one of the four that costs nothing to maintain. This section is what that rule
actually rests on, because "value type" is not the same claim as `struct`.

### `struct` is a syntax; value semantics is a property

A type has value semantics when a copy is independent of the thing it was copied
from: mutating one is not observable through the other. Structs of `Int`,
`String`, `Array` and other structs have it. A struct with one stored reference
does not, and nothing says so:

```swift
struct Draft {
    private final class Body { var text = "" }
    private var body = Body()
    var text: String {
        get { body.text }
        set { body.text = newValue }
    }
}

var a = Draft(); var b = a
b.text = "edited"
a.text        // "edited"
```

That compiles in Swift 6 language mode with no warning, and it is not a data
race — one thread, no concurrency involved. It is worse than a class would have
been, because `var b = a` reads as a copy at every call site.
`ImmutabilityTests` keeps that type compiled and runs it, for the same reason
`SingleFlightCacheTests` keeps its naive actor: an assertion about a mistake is
weaker than the mistake, executed.

It matters for concurrency because value semantics is *exactly* the property
that makes `Sendable` inference sound. The compiler catches the version of this
where the class is not `Sendable`. It does not catch the version where the class
is — a `final class` whose state lives inside an `OSAllocatedUnfairLock` is
`Sendable`, so a struct wrapping one is `Sendable` too, and its copies share.
That type is safe to send and still not a value.

### `let`-first, and what a transform is for

`User` now has no `var` stored properties. It never needed any: nothing in the
package has ever mutated a `User` in place, because a domain model fetched over
HTTP is edited by the server and comes back as a new value. Writing that as
`let` costs nothing and buys three things — no partially-updated state for a
reader to reason about, an `==` that stays true, and a type that is `Sendable`
by inspection.

What it takes away is `user.name = "Ada"`, and what replaces it is a
derivation. The obvious spelling of one is a method whose parameters default to
`nil`, and it has a hole in it:

```swift
func with(name: String? = nil, avatarURL: URL?? = nil) -> User
```

`name` is fine. `avatarURL` is already optional, so "not supplied" and "set to
nil" have collided, and the double optional that resolves it in the type does
not resolve it at the call site: `user.with(avatarURL: nil)` compiles, reads as
*clear the avatar*, and means *leave the avatar alone*, because `nil` binds to
the outer optional. Both readings type-check, so there is no diagnostic — only a
field that silently fails to clear.

`FieldUpdate` names the two cases instead of documenting the trap:

```swift
user.with(name: .set("Ada"))       // rename, keep the avatar
user.with(avatarURL: .set(nil))    // clear the avatar, keep the name
```

`with(_:)` takes no `id` and no `email`. A transform's parameter list is the
type's statement about what an edit is allowed to touch, and changing either of
those does not produce an edited user — it produces a different one, which the
memberwise initialiser is for.

The rebuild-by-hand this replaces was live in the package and losing data.
`MockUserRepository.updateProfile(name:)` read
`User(id: stubbedUser.id, email: stubbedUser.email, name: name)`, which threw
away the avatar and both timestamps every time it ran, because the memberwise
initialiser defaults them to `nil`. A transform cannot drop a field it was not
asked about.

### Copy-on-write, and inspecting it rather than believing in it

Value semantics sounds expensive: if every assignment copies, a struct holding a
large array is a copy per assignment. It is not, because the standard library's
containers are copy-on-write — assignment shares the buffer and refcounts it, and
the *first mutation through a shared reference* is what allocates.

That is a performance claim, and a performance claim nothing measures is a hope.
Two arrays share a buffer exactly when their base addresses are equal, which is
observable without escaping a pointer:

```swift
lhs.withUnsafeBufferPointer { left in
    rhs.withUnsafeBufferPointer { right in
        left.baseAddress == right.baseAddress
    }
}
```

`StandardLibraryCopyOnWriteTests` uses it to pin both halves: assignment shares,
and appending to one of two sharers gives it its own buffer while the other keeps
the original. It also checks the inherited case — `ScanResult` stores an array,
declares no copy-on-write of its own, and gets it anyway.

**`CopyOnWriteBox` is almost always the wrong tool**, and that is worth saying in
the file that ships it. `Array`, `Dictionary`, `Set`, `String` and `Data` already
do this; a struct built from them inherits it for free, and every model in this
package is that shape. Putting a hand-rolled box in front of one adds an
allocation and buys nothing. It earns its place in exactly one situation: a value
type that must store a *reference* and must still behave like a value — which is
`Draft` above, with the missing line put back.

The missing line is the whole mechanism:

```swift
private mutating func makeUnique() {
    guard !isKnownUniquelyReferenced(&storage) else { return }
    storage = Storage(storage.value)
}
```

`isKnownUniquelyReferenced(_:)` reads the object's reference count, which is
precisely the question *does anyone else see the write I am about to make*. It is
`mutating` and takes its argument `inout` because it needs exclusive access to
the reference it is asked about — which is also why a box held in a `let` cannot
be asked, and why `CopyOnWriteBox.isUniquelyReferenced()` is `mutating` in turn.

Two things the box exposes are there to be tested rather than used:
`storageIdentity` reports which allocation a box currently points at, and
`isUniquelyReferenced()` reports whether the next mutation will copy. Between
them `CopyOnWriteBoxTests` states the contract as measurements — sharing after
assignment, one copy on the first write through a shared box, no copy at all when
the box is the only owner, and uniqueness returning to the original once a copy
has diverged.

One consequence is easy to miss: **mutate through `withValue`, not through
`value`**. `value` is a computed property, so `box.value.append(1)` is a get, a
mutation of the temporary, and a set — it copies the payload out and back on
every call, and defeats the payload's own copy-on-write while doing it.
`withValue` yields the storage `inout` and mutates in place. The accessor that
would close the gap on the property itself is the underscored `_modify`, which is
not language surface this package is willing to depend on.

## What enforces all of this

Nine gates, none of which depend on anyone remembering the rules:

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
- **`Tests/ViewModelTests/DelegateStreamTests.swift`**. Asserts what each
  buffering policy keeps and what it throws away, including the unbounded
  spelling — compiled and run rather than described, for the reason
  `ConcurrentMapTests` keeps its unbounded task group. It also pins the
  superseding rules: that a replaced stream ends instead of hanging, that its
  termination does not detach the stream that replaced it, and that being
  replaced is not reported as the producer becoming unwanted.
- **`Tests/ViewModelTests/DiagnosticsActorTests.swift`**. Asserts that the
  diagnostics domain landed where its documentation says: off the main thread,
  and on the executor's own queue rather than the cooperative pool. The second
  of those is the one that matters, because losing `unownedExecutor` from
  `DiagnosticsActor` breaks nothing visible — the actor stays correct and stays
  serial, and only stops being on a thread it is allowed to block. It is checked
  through the executor's own `checkIsolated()`, so a wrong answer trips a
  `dispatchPrecondition` and takes the process with it rather than failing
  quietly. The suite also pins the ordering claim from the other end: sixty-four
  concurrent `record` calls produce sixty-four consecutive sequence numbers,
  which is the actor's serialisation observed through the thing that would
  visibly break without it.
- **`Tests/ViewModelTests/ImmutabilityTests.swift`**. Measures value semantics
  rather than assuming it. The struct-over-a-reference that silently has
  reference semantics is compiled and run, next to the same shape with
  `makeUnique()` put back, so the difference is a test result rather than a
  paragraph. It also pins the copy-on-write claims as observations —
  `storageIdentity` for `CopyOnWriteBox`, buffer base addresses for `Array` —
  and the `with(_:)` transform's promise that a field it was not asked about
  survives the edit, which is the bug it was introduced to fix.
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
