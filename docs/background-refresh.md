# Background refresh: `BGTaskScheduler`, constraints, and two kinds of retry

Phase 9 item 2. What the app asks the system for while nobody is looking at it,
which of the two request types can carry a constraint and which cannot, and why
"retry" here means two separate mechanisms rather than one.

## The handler that stops working

Almost every first implementation of background refresh is this, and it is
wrong in three ways that only appear once the network does:

```swift
BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
    Task {
        try? await refresh()                 // 1, 2
        schedule(after: .minutes(15))         // 3
        task.setTaskCompleted(success: true)
    }
}
```

**1. `try?` throws the outcome away.** iOS rations background time by how
useful an app's previous launches were, and `setTaskCompleted(success:)` is the
only channel it is told through. An app that reports success for a run that
failed spends its budget on launches that achieve nothing, and its failures are
invisible — which is why the usual bug report is "it just stopped working" with
no error anywhere.

**2. A failure retries on exactly the schedule a success does.** A server that
is down is asked again in fifteen minutes, and again, from every installation
that has the app. That is the thundering herd `Backoff` documents, arriving over
hours instead of seconds, from clients that are not even running.

**3. The reschedule is on the success path.** Anything that leaves the handler
early — a throw, an expiration, a crash — leaves *nothing pending*. A background
task with no pending request is never launched again, so the feature does not
degrade, it stops, and it stops first on the devices that were already
struggling. This is the single most common way background refresh dies in
shipped apps.

`BackgroundRefreshCoordinator` (`Sources/Core/Background/`) answers all three.

## What runs, and where

| Type | Job |
| --- | --- |
| `BackgroundRefreshRequest` | A value describing what to ask for. `systemRequest()` turns it into a `BGTaskRequest`. |
| `BackgroundTaskScheduling` | The submit/cancel seam. `SystemBackgroundTaskScheduler` in the app, `MockBackgroundTaskScheduler` everywhere else. |
| `BackgroundRefreshLedger` | The consecutive-failure count, persisted so it outlives the process. |
| `BackgroundRefreshPolicy` | Identifier, kind, interval, reschedule backoff, in-flight retry budget. |
| `BackgroundRefreshCoordinator` | Schedules, runs, and decides when to ask again. |

Registration is deliberately not in that list. `BoilerplateApp` uses SwiftUI's
`.backgroundTask(.appRefresh(_:))` scene modifier, which does the registration,
the completion call, and the expiration plumbing — the three things a
hand-written `register(forTaskWithIdentifier:using:)` has to get right and
usually gets wrong on the third.

## Constraints belong to one request type, not both

`BGAppRefreshTaskRequest` has exactly one knob: `earliestBeginDate`. It cannot
say "only on Wi-Fi" or "only on the charger". `BGProcessingTaskRequest` can say
both. So `BackgroundRefreshKind` is an enum whose `.processing` case carries a
`BackgroundRefreshConstraints` and whose `.appRefresh` case has nowhere to put
one:

```swift
case appRefresh
case processing(BackgroundRefreshConstraints)
```

A single struct with two `Bool`s on every request would have compiled, read
better, and advertised a guarantee the system never made for the app-refresh
case. The enum makes the asymmetry a compile-time fact, and
`BackgroundRefreshRequestTests` pins the mapping in both directions.

The two constraints are not interchangeable in cost:

- `requiresNetworkConnectivity` holds the launch until there is a connection, so
  a run that starts is a run that had one. It also lets the system kill the task
  when connectivity drops, so the handler still cannot assume it will finish.
- `requiresExternalPower` holds the launch until the device is plugged in. On a
  phone that charges overnight, that is once a day. It is right for a bulk
  re-encode or a full re-index, and wrong for a poll — the failure mode is that
  the feature silently does nothing for anyone who charges from a laptop.

The app's profile refresh is an `.appRefresh` task. It wants to be timely more
than it wants a guarantee, and the work it does is one small GET.

## Two retries, because there are two failures

**Inside one launch — `Retry.run`.** A transport blip gets a second attempt,
seconds later, on a jittered backoff. The budget is deliberately small
(`maxAttempts: 2`, capped at 8s): a `BGAppRefreshTask` is budgeted in tens of
seconds, so a generous attempt count does not produce four attempts, it produces
one attempt and an expiration. `Retry.isTransient` decides what qualifies, which
is what keeps an unattended launch from repeating a request the server has
already refused — a 401 in the background is not retried, it is a failed refresh
that backs off and lets the next foreground launch deal with the session.

**Across launches — the ledger and the reschedule.** This is the one an
in-process retry cannot do. A background task is not a loop inside a running
app: each launch is very often a new process, so anything the last attempt
learned is gone. An in-memory failure count reads zero on almost every run, and
a backoff computed from it is not a backoff — it schedules the nominal interval
forever. `UserDefaultsBackgroundRefreshLedger` keeps the count in defaults
(a small integer with nothing to protect — CLAUDE.md's rule is about *tokens*),
namespaced by task identifier so two scheduled tasks cannot pace each other, and
clamped, because the count is an exponent.

### The jitter is `.equal` here and `.full` in `Retry`

`Backoff`'s default is `.full` — `random(0, term)` — because for an in-flight
retry loop, spreading the herd is worth more than any one client's latency, and
the loop is bounded anyway.

The reschedule schedule is unbounded, each attempt costs a process launch and a
radio wake, and `.full` leaves the *floor* at zero however far the expected
delay has grown: a device on its ninth consecutive failure can still ask to be
launched almost immediately. `.equal` — `term/2 + random(0, term/2)` — keeps
half of each term deterministic, so the backoff has a floor that actually grows,
and randomises the other half, which is the part that keeps a million devices
from all returning the instant an outage ends.

## The shape of one launch

```
handle()
 ├─ submit(next launch)          ← before anything that can be killed
 ├─ Retry.run { refresh() }
 ├─ success  → ledger.recordSuccess(); submit(now + interval);   .refreshed
 ├─ failure  → ledger.recordFailure();  submit(now + backoff);   .failed
 └─ expired  → (ledger untouched, entry submission stands)       .expired
```

Two submissions per launch is deliberate. Submitting an identifier that already
has a pending request *replaces* it rather than queueing a second, so the cost
is one extra call and the benefit is that there is no window in which the chain
is broken — defect 3 above, closed.

Expiration is not a failure. The system took its time back; nothing was learned
about whether the work would have succeeded, and counting it would back the
schedule off for a reason the network never gave. It is also not success:
`.expired` is reported as such, so the system's own accounting stays honest.

`.backgroundTask` cancels the surrounding task when the system expires it, which
is why the coordinator needs no expiration API of its own — `Retry.run` refuses
to retry a cancelled operation, and the outcome falls out of the error.

## A cached answer is a failed refresh

The background leg asks the factory for `.remoteFirst` rather than reusing the
app's resolved strategy, for the same reason the pull-to-refresh gesture does:
under `offlineFirst`, a read inside the freshness window is answered off the row
and costs no request, which is right for a screen and a wasted process launch
for a task whose whole job is to make that row fresher.

But `RemoteFirstSyncStrategy` is deliberately forgiving — asked with the radio
down it answers out of the store and reports `SyncOrigin.localCache` instead of
throwing. For a screen that is correct. For the ledger it is not: a launch that
read its own disk has refreshed nothing, and counting it as a success would
clear the failure count, collapse the backoff, and leave an offline device
waking every fifteen minutes to re-read the same row. So `AppContainer.live()`
inspects the origin and throws `BackgroundRefreshFailure.answeredFromCache`.

`.remoteOnly` was the other candidate and never falls back — but it also never
writes through, so a successful background fetch would leave the store exactly
as stale as it found it.

## What the consuming app must add

This package cannot carry these; they live in the app target's Info.plist, and
a missing identifier is **raised, not thrown** — the first `submit` traps, and
no `do/catch` helps.

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.example.boilerplate-ios-swift.refresh-profile</string>
</array>
<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
</array>
```

Add `processing` to `UIBackgroundModes` as well if you switch the policy's
`kind` to `.processing`. Change the identifier in
`AppContainer.backgroundRefreshIdentifier` and in the plist together — they are
one string in three places, and only two of them are Swift.

## Testing it without waiting hours

`BGTaskScheduler.submit` raises `NSInternalInconsistencyException` for an
identifier that is not in the host's `BGTaskSchedulerPermittedIdentifiers`, and
a unit-test bundle has no such array. That is the whole reason
`BackgroundTaskScheduling` exists: with the seam, every scheduling decision is
assertable in milliseconds against `MockBackgroundTaskScheduler`, with an
injected clock, an injected sleep and an injected jitter source, so a delay is
an equality rather than a tolerance.

Building a `BGTaskRequest` needs no entitlement — only submitting one does — so
`systemRequest()` is checked directly rather than through the seam, which is
what keeps the `.processing` branch from being code no test can reach.

To drive the real thing on a device, pause in the debugger after the app
backgrounds and run:

```
e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.example.boilerplate-ios-swift.refresh-profile"]
```

That is a private, debugger-only entry point. It is not in the package, and it
must not find its way in.
