# Factory + Strategy: the sync policy

Phase 8 item 3. How a read of the signed-in user is satisfied across the API and
the local store, why that decision is an object rather than a branch, and what
this item deliberately left for Phase 9.

## The problem it was given

`docs/solid.md` finding 6 is the one the audit called the finding that reframes
the rest of the page: **the repository layer was not on any data path.** No view
model held a `UserRepository`. No view model held a `UserPersistenceService`.
`BoilerplateApp` opened a `ModelContainer` and installed it in the environment,
and nothing read it. The one screen that displayed a list built the list itself,
with a `Task.sleep` standing in for latency.

Phase 8 item 2 narrowed that by half — `AppContainer.live()` started constructing
a `LiveUserRepository` — and the audit was careful to say that a layer with a
constructor is still not a layer with a caller. This item is where the caller
arrives, and the finding named it in advance: item 3 and Phase 9 item 1 are
"both items that cannot be written without giving these types a caller".

So there are two things to get right, and only one of them is a design pattern.

## The chain that now exists

```
SettingsView
  → ProfileFeature                   (the caller; a Store since Phase 8 item 6)
    → ProfileEffectHandler           (where the strategy is actually held)
    → SyncStrategy                   (the policy: which side answers)
      → UserRepository → APIClient   (the network leg)
      → UserPersistenceService       (the local leg)
```

Every hop is a protocol, and every implementation behind those protocols is
chosen in `AppContainer`. The auth path — `LoginView` → `LoginViewModel` →
`LiveAuthService` → `URLSessionAPIClient` → `TokenStore` → `KeychainWrapper` —
was the only complete chain in the package, and the audit's summary of the shape
this repo wants was "it exists once". It exists twice now, and the second one is
the one with a store on the end of it.

## Strategy

`SyncStrategy` has two requirements — `loadCurrentUser()` and
`updateProfile(name:)` — and three implementations that differ in exactly three
respects: who is asked first, whether the answer is written back, and what
happens when the device cannot reach the host.

| Policy | Read | Write-through | Offline |
| --- | --- | --- | --- |
| `remoteOnly` | API | none — it holds no store | fails |
| `remoteFirst` | API | yes | serves the cached row |
| `cacheFirst` | cache while fresh, else API | yes | serves the cached row, stale or not |
| `offlineFirst` | the row while fresh, else API | yes, and it stamps the row | serves the row, stale or not |

Phase 9 item 1 added the fourth and made it the app's default; it has a page of
its own, [`docs/offline-first.md`](./offline-first.md), because it is the only
one that changes which side is *authoritative*. The three above are variations
on "the API is the truth and the store is a copy of its last answer", and
everything in the rest of this page is about them.

`remoteFirst` was the default before that, because it is the conservative one: a
read costs a request, so the screen is never quietly older than the call that
produced it — and when it is, `SyncedUser.origin` says so and `SettingsView`
renders "Showing a saved copy". That argument did not lose, it moved: it is now
the argument for the refresh *gesture*, which is the policy `ProfileFeature`
asks the factory for by name.

Three things about that table are worth stating rather than leaving to be read
out of the code.

**`remoteOnly` holds no store at all.** It is not "a strategy that happens not
to write"; it has no store property, so a reader can see there is no cache path
to reason about.

**Only a transport failure falls back.** `SyncFailure.isOffline(_:)` returns
true for `APIError.networkUnavailable` and `UserRepositoryError.networkUnavailable`
and nothing else. A 401 must not be answered from the cache — the session is
gone, and serving the last-known profile makes a signed-out app look signed in.
A decoding failure is a bug, and hiding it behind the cache is how it survives
to the next release.

**Two error types are matched because the layer throws two.** That is
`docs/solid.md` finding 4 — `LiveUserRepository` surfaces `APIError` while
`MockUserRepository` throws `UserRepositoryError`, and nothing reconciles them.
This is the first production code to pay for it. Matching one would mean the
policy behaved differently under test than in the app, which is worse than the
duplication. The fix is Phase 8 item 4's: a decorator between the client and the
repository is the layer that gets to own error translation.

## Factory

`SyncStrategyFactory` builds a strategy for a policy.
`AppContainer.live(syncPolicy:)` resolves the app's declared policy once, at
startup, and the container carries **both** the resolved strategy and the factory
that made it.

That is not redundancy. Two callers want different things:

- Everything that just needs to read a profile takes `container.syncStrategy`,
  and has no opinion about caching.
- A caller with a reason to depart from the app's policy asks the factory for the
  one it needs. There is exactly one such caller today and it is the reason the
  seam exists: **pull-to-refresh**. Under `cacheFirst`, the container's strategy
  would answer a refresh gesture from the very cache the gesture is trying to get
  past. `ProfileFeature`'s `.refreshProfile` effect asks for `.remoteFirst` — "go to
  the server, but do not fail if I am offline" — without knowing which type
  implements that.

`SyncPolicy` is a closed enum rather than an open registry, for the same reason
`AppContainer` is a struct of stored properties rather than a type-keyed
dictionary (see [`docs/dependency-injection.md`](./dependency-injection.md)):
the compiler checks that the factory still covers every case, so adding a policy
is a build failure at the one place that has to answer for it.

Each `makeStrategy(for:)` call builds a new object. `cacheFirst` carries a
freshness window as mutable state, and a factory whose product is shared is a
singleton with extra steps.

## Two decisions that are easy to get quietly wrong

### The write-through is an upsert, spelled at the call site

`docs/solid.md` finding 3 records that `SwiftDataUserPersistenceService.save(user:)`
**inserts** while `MockUserPersistenceService.save(user:)` **upserts**, and
predicts the caller that would expose it: "a *save on every launch* caller reads
back a stable value in tests and an arbitrary one on device". This item is that
caller. Writing `store.save(user:)` on every successful read would have landed
the bug the audit described, in the same release as the page describing it.

So every write goes through `UserPersistenceService.writeThrough(_:)`, a
protocol extension that updates the row if it is there and inserts it if it is
not. Both implementations then agree. Fixing `save(user:)` itself would have
been the other option and it is not this item's to take — it is a change to the
store's contract, and the audit assigns it to Phase 9 item 1.

`repeatedReadsDoNotAccumulateRows` pins it against the **real** SwiftData store
rather than the double, because the double would have agreed either way.

> Phase 9 item 1 took the decision the audit deferred: `save(user:)` upserts on
> both implementations now, so `writeThrough(_:)` is one call rather than an
> update-then-insert dance. What it still is, and is more of, is the place the
> confirmation stamp is written — "written through" means "the server just said
> so", and that is now recorded on the row.

### The freshness window is monotonic and in memory

`cacheFirst` measures its window with `ContinuousClock` and holds the last
refresh instant in memory for the life of the process. Not persisted beside the
row, and not measured on the wall clock.

- A stored "fetched at" column is a schema change, and versioned schemas plus
  migration tests are Phase 9 item 4. Adding a column here would land an
  unversioned migration inside an item about a design pattern.
- `ContinuousClock` does not move when the wall clock does, so a device that
  crosses a timezone or syncs its clock backwards does not end up with a cache
  that is suddenly fresh for an hour.

The cost, stated plainly: **a cold launch always goes to the network**, because
nothing in memory says when the cached row was fetched. That is the safe
direction to be wrong in, and `firstReadGoesToTheApi` pins it as behaviour
rather than leaving it as a comment.

`now` is injected as a `@Sendable () -> ContinuousClock.Instant`. Phase 7
recorded that `withTimeout` shipped with no clock seam and that its suite
therefore measures real durations; this is that lesson applied while the code was
being written instead of afterwards.

> Phase 9 item 1 persisted the stamp, on a new optional column, and paid the
> price this section names: a wall-clock stamp is a stamp that can be moved, so
> `offlineFirst` treats a row stamped in its own future as stale. Both windows
> now exist side by side, which is deliberate —
> [`docs/offline-first.md`](./offline-first.md) has the comparison.

## What propagates and what does not

A write-through failure **propagates**. A store that cannot accept the row is a
cache that will be silently useless from then on, and "the profile saved but your
device did not keep it" is a state a caller should be able to see.

The one place a failure is swallowed is `UserPersistenceService.cachedUser()`,
which is only ever called from the fallback arm of a read that has *already*
failed because the device is offline. Rethrowing there would replace "you are
offline", which the reader can act on, with a disk error they cannot.

"Log and carry on" is a policy too, and it belongs in the telemetry decorator
Phase 8 item 4 adds — not hardcoded here, which is the shape of finding 7.

## What this item did not do

- **It did not make SwiftData the source of truth.** That is Phase 9 item 1, and
  it is a different item because it changes which side is *authoritative*, not
  which side is asked first. Everything here treats the API as the truth and the
  store as a copy. ~~Still open.~~ Done — [`docs/offline-first.md`](./offline-first.md).
- **It did not fix `save(user:)`.** Finding 3 stands, `saveDivergesBetweenImplementations`
  still passes, and `writeThrough(_:)` is the call-site answer in the meantime.
  ~~Still open.~~ Done in Phase 9 item 1: both implementations upsert, and the
  pin is inverted to `saveAgreesBetweenImplementations`.
- **It did not reconcile the error types.** Finding 4 stands, and
  `SyncFailure.isOffline(_:)` knows about both vocabularies as a result. So does
  `SyncErrorMessage`, which exists only because a `catch` at a screen has no
  single concrete type to name.
- **It did not collapse concurrent refreshes.** Two loads that both find the
  window expired both go to the network. `SingleFlightCache` is what that is for,
  and wrapping it round the repository is a decorator, not a branch inside a
  policy. The duplicate request is a cost, not a correctness bug, because the
  write-through is an upsert.
- **`HomeViewModel` still fabricates its list.** Finding 6 is about two types and
  this repairs both of them; the home screen's `Task.sleep` is a separate,
  smaller gap, and it needs a list endpoint rather than a policy.

## Where the pins are

| Claim | Test |
| --- | --- |
| Each policy resolves to a strategy that reports it | `SyncStrategyFactoryTests.everyPolicyResolves` |
| The root resolves the policy it was given | `AppContainerTests.liveResolvesTheRequestedSyncPolicy` |
| `remoteFirst` is the default | `AppContainerTests.liveDefaultsToRemoteFirst` |
| A cached answer is reported as cached | `ProfileFeatureTests.cachedAnswerIsReportedAsCached` |
| Refresh asks for a network-going policy | `ProfileFeatureTests.refreshAsksTheFactoryForRemoteFirst` |
| An expired session is not answered from the cache | `RemoteFirstSyncStrategyTests.expiredSessionIsNotAnsweredFromTheCache` |
| Repeated reads leave one row in SwiftData | `RemoteFirstSyncStrategyTests.repeatedReadsDoNotAccumulateRows` |
| The freshness window opens, holds and expires | `CacheFirstSyncStrategyTests` |
| The live graph binds the store and the strategy | `SolidContractTests.liveContainerBindsTheLiveGraph` |

## What is not pinned

- **Nothing checks that the app's chosen policy is a good one.** `remoteFirst` is
  a default with an argument behind it, not a measurement.
- **The concurrent-refresh window is untested.** Two simultaneous expired reads
  both fetch; that is documented above and not asserted, because asserting it
  would pin the behaviour this repo intends to replace with a decorator.
- **`SettingsView`'s rendering is not exercised.** As with every other screen,
  `PreviewProviderTests` constructs it and stops there — the test target has no
  SwiftUI host to evaluate a body in. That the offline banner appears when
  `origin == .localCache` is checked in the view model, not on screen.
