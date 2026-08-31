# Offline-first: SwiftData as the source of truth

Phase 9 item 1. What changes when the store stops being a copy of the API's last
answer and becomes the thing a read is answered from, what that costs, and the
two repairs it forced on the store underneath.

## The one-line difference

`RemoteFirstSyncStrategy` and `CacheFirstSyncStrategy` both read like this:

```swift
let user = try await repository.fetchCurrentUser()   // the truth
try await store.writeThrough(user)                   // the copy
```

The store appears in a `catch`, or behind a window, and either way the value
handed back is the response. `OfflineFirstSyncStrategy` inverts it:

```swift
let stored = try await store.fetchCurrentRecord()    // the truth
if stored.isFresh { return stored }                  // no request at all
let fetched = try await repository.fetchCurrentUser()
return try await persist(fetched)                    // → the row, read back
```

Three properties follow, and none of them is available to the policy above it.

> Phase 9 item 3 put one line in front of that `persist`. Inverting which side
> is authoritative is what gives the row standing to *refuse* a response, and
> until that item nothing exercised it: a fetched copy of an older write was
> written over the row and then stamped as confirmed. The merge policy is what
> now decides — [`docs/conflict-resolution.md`](./conflict-resolution.md).

### A cold launch inside the window makes no request

`cacheFirst` holds its last-refresh instant in memory for the life of the
process, and `docs/sync-strategy.md` states the cost plainly: the first read
after launch always goes to the network, because nothing says when the row was
fetched. `firstReadGoesToTheApi` pins that as behaviour.

Here the stamp is a column on the row, so the second launch of the app half a
minute after the first renders the profile with the radio idle.
`coldLaunchInsideTheWindowMakesNoRequest` builds a *fresh* strategy over a
stamped store — a strategy that has never seen it, exactly as a relaunched
process has not — and
`OfflineFirstSyncStrategyStoreTests.secondStrategyInheritsTheWindow` does the
same against real SwiftData.

### The strategy is a value with no state

`CacheFirstSyncStrategy` is a `final class` holding an `OSAllocatedUnfairLock`
around a mutable instant, and `LiveSyncStrategyFactory` has to vend a fresh
instance per call so one screen's read cannot reset another's window.

`OfflineFirstSyncStrategy` is a `struct`, because everything it would have
remembered is on disk. Two instances built over the same store share a window
automatically — that is the same fact as the paragraph above, seen from the
other end.

### A failed refresh is not a failed read

When there is a row, an offline refresh returns it. The read only fails when the
device has never successfully synced, which is the one state an offline-first
app genuinely has nothing to show for.

## What it deliberately does not soften

**A 401 still propagates.** Only a transport failure falls back to the row, and
`SyncFailure.isOffline(_:)` was not widened for this policy. Being the source of
truth is a claim about where a value comes from, not a licence to serve it after
the server has said the caller may not have it — the failure mode is a
signed-out app that goes on looking signed in.
Pin: `expiredSessionIsNotAnsweredFromTheStore`.

**A store failure fails the read.** The primary read propagates rather than
falling through to the network. Quietly answering from the API would turn the
one policy that promises a durable answer into `remoteOnly` at exactly the
moment a reader would most want to be told, and it would do it silently.
Pin: `storeFailureFailsTheRead`, which also asserts the repository was never
asked.

**There is still no local-only write.** `updateProfile(name:)` goes to the API
and fails if it cannot. An edit that never leaves the device needs an outbox and
a merge rule; item 3 supplied the rule — see
[`docs/conflict-resolution.md`](./conflict-resolution.md) — and the queue, with
the client-generated keys that make a replayed request idempotent, is still
ahead. Being offline-first about reads does not make a queued write free. Pin:
`offlineWriteFails`.

## The stamp

`StoredUser` carries the row and the moment it was last confirmed with the API,
as one value out of one fetch — reading them separately is a torn read, and a
policy that asked "who is the user" and then "when was that refreshed" could be
answered about two different writes.

`refreshedAt` is a wall-clock `Date`, which is the *opposite* of the choice
`cacheFirst` makes, and it is forced. A `ContinuousClock.Instant` is an offset
from an origin the next launch does not share, so a monotonic stamp means
nothing once the process that minted it is gone — and surviving the launch is
the entire point.

That buys back the problem `cacheFirst` avoided: a wall clock moves. Three
states are stale, and only the first is obvious.

| Row | Fresh? | Why |
| --- | --- | --- |
| confirmed inside `maxAge` | yes | the ordinary case |
| confirmed longer ago than `maxAge` | no | the ordinary case |
| never confirmed (`nil`) | no | "no stamp" is not "just refreshed" |
| confirmed in the *future* | no | the clock moved; trusting the magnitude alone keeps the row fresh for as long as the skew lasts |

`StoredUserFreshnessTests` covers all four. The cost of the third row is one
request after a seed or a restore; the cost of getting the fourth wrong is a
device that never refreshes until someone corrects its clock.

Both windows now exist side by side, and that is deliberate rather than
transitional: `cacheFirst` is the right shape when a stale answer after a
relaunch would be wrong, and `offlineFirst` is the right shape when a launch
with no connection should still show something.

## The read-back, and why it is not pedantry

`persist(_:at:)` writes the row, then reads it back by `id`, and returns what
came out. Returning the API's response directly would be one call cheaper.

It would also have been wrong in this very repository until this item.
`SwiftDataUserPersistenceService.update(user:)` wrote three of the five mapped
columns — `name`, `avatarURL`, `updatedAt` — and left `email` and `createdAt` on
whatever the row already held. Under `remoteFirst` that was survivable, because
the next read came from the API and corrected the screen. Under this policy it
is a profile whose email changed on another device, was written to disk, was
silently truncated, and was then served back as the truth on every subsequent
launch. A bug that only appears after a relaunch is the worst kind to own.

So the value on screen is the value on disk, in the same call, or the read
fails. `returnedValueIsTheRowRatherThanTheResponse` uses a store that keeps the
write but alters it; `storeThatKeepsNothingFailsTheRead` uses one that drops it.

The lookup is by `id` rather than through `fetchCurrentRecord()` on purpose:
"the current user" is a question the store answers by `createdAt`, and **nothing
clears this store on sign-out yet**, so a previous account's row can still be in
it and can still be the newest. Naming the row that was just written sidesteps
that. Clearing the store on sign-out is a real gap and is listed below.

## What this item repaired underneath

Both are `docs/solid.md` finding 3, which the audit explicitly assigned here.

**`save(user:)` is an upsert on both implementations.** It inserted in the store
and upserted in the double, so saving the same user twice left two rows on
device and one entry under test, and `fetchCurrentUser()` chose between the rows
on `max(by:)`'s unspecified tie-break. That was a value read back before; it is
what the app displays now. `UserEntity.id` still carries no
`@Attribute(.unique)` — the constraint traps on an in-memory store, which is
every store the tests and previews run on — so uniqueness is enforced by the
write. The differential pin is inverted: `saveAgreesBetweenImplementations`.

**`update(user:)` writes every mapped field.** See the read-back section for the
failure it caused.

## The schema change

`UserEntity` gained one optional attribute. That is the cheapest shape a schema
change has: SwiftData's implicit lightweight migration adds it to an existing
store with no migration plan and fills it with `nil`, which is exactly what an
unconfirmed row should say.

`docs/sync-strategy.md` declined to add this column in Phase 8 on the grounds
that versioned schemas and migration tests are Phase 9 item 4, and that adding
one would land an unversioned migration inside an item about a design pattern.
That reasoning holds and this item is where the same page said the stamp
belonged. What is honest to say: this column is what item 4 will migrate
*from*, and it is not itself covered by a `VersionedSchema`.

> There are two such columns now. Phase 9 item 3 added `version` on the same
> terms and for the same reason, so item 4 inherits both.

## Where the pins are

| Claim | Test |
| --- | --- |
| A launch inside the window costs no request | `coldLaunchInsideTheWindowMakesNoRequest` |
| …including against real SwiftData | `secondStrategyInheritsTheWindow` |
| An unstamped row is refreshed | `unstampedRowIsRefreshed` |
| An aged row is refreshed and restamped | `agedRowIsRefreshedAndRestamped` |
| An offline refresh serves the row | `offlineRefreshServesTheStoredRow` |
| A 401 is not answered from the store | `expiredSessionIsNotAnsweredFromTheStore` |
| A never-synced device fails offline | `offlineReadWithAnEmptyStoreFails` |
| A store failure is not a silent downgrade | `storeFailureFailsTheRead` |
| The value returned is the row | `returnedValueIsTheRowRatherThanTheResponse` |
| A write restamps the row | `writeRestampsTheRow` |
| A write is not queued offline | `offlineWriteFails` |
| Repeated refreshes leave one row | `repeatedRefreshesLeaveOneRow` |
| A refresh persists every field | `refreshPersistsEveryField` |
| The four freshness verdicts | `StoredUserFreshnessTests` |
| `save` agrees across implementations | `saveAgreesBetweenImplementations` |
| The app resolves this policy by default | `AppContainerTests.liveDefaultsToOfflineFirst` |
| The live graph binds this strategy | `SolidContractTests.liveContainerBindsTheLiveGraph` |

## What is not pinned, and what is not done

- **Nothing clears the store on sign-out.** The signed-in user's row outlives
  the session, so the next account's first read can find a stranger's profile as
  "current". The read-back sidesteps it for the value this policy returns; it
  does not fix it. It needs a `SessionObserver` that deletes, and it is a
  session concern rather than a policy one.
- **Concurrent refreshes are still not collapsed.** Two stale reads at once both
  go to the network. `SingleFlightCache` behind `CachingUserRepository` already
  narrows this in the live graph; the duplicate is a cost rather than a
  correctness bug, because the write is an upsert.
- **The window is not persisted per-resource.** One stamp, on one row, for one
  profile. A list endpoint would need the stamp keyed by query, which is what
  pagination (item 6) will have to answer.
- **`maxAge` is a default, not a measurement.** Five minutes is inherited from
  `LiveSyncStrategyFactory.defaultCacheMaxAge`, shared with `cacheFirst`,
  because the two policies differ in where they record the answer and not in
  what it should be.
- **Background refresh is item 2.** Nothing here refreshes a stale row without
  someone reading it.
