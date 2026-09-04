# Decorating the repository layer

Phase 8 item 4: "Decorator pattern: repository wrappers adding cache, retry, and telemetry".

Three wrappers around `UserRepository`, each adding one behaviour, composed once in
`AppContainer.live()`. This page is the argument for each of them, the argument for the
order they are in, and the list of what the item deliberately did not do.

The finding this item exists to close is [`docs/solid.md`](./solid.md) finding 7: the only
retry policy in the package was welded into `URLSessionAPIClient.performRequest`, and Phase
7 had shipped `Retry`, `Backoff` and `withTimeout` with the spec recording that **nothing
called any of them**, because "wiring in a policy is a decision about which endpoints are
idempotent" and there was nowhere to express that decision.

## The chain

```
TelemetryUserRepository        // measures what the caller waited for
  └─ CachingUserRepository     // collapses repeated and concurrent reads
       └─ RetryingUserRepository   // repeats what is worth repeating, under a deadline
            └─ LiveUserRepository  // APIClient
```

Each link conforms to `UserRepositoryDecorator`, which is `UserRepository` plus a `base`.
That requirement exists so the order is assertable: `decoratorChainIsTelemetryOverCacheOverRetry`
walks the container's resolved repository down to `LiveUserRepository` and checks all four
names in sequence.

## Why this order

Ordering is the configuration. Every pair below is a real decision, and the alternative is
not wrong so much as an answer to a different question.

**Retry innermost.** Retrying is a statement about a request, so it belongs closest to the
thing that makes requests. Above the cache it would repeat cache lookups, which cannot fail
in an interesting way; below it, one memo fill absorbs the whole retry sequence and a cache
hit does no retry work at all.

**Cache above retry.** The consequence is that the *cost* of a retry is paid once per memo
fill rather than once per reader. Fifty views asking for the profile while the network is
flaky produce one request, one retry sequence and one answer, which is `SingleFlightCache`'s
subject.

**Telemetry outermost.** What it records is what the caller experienced: retries, backoff
sleeps and cache hits are all inside the number. A screen that took four seconds to show a
profile is four seconds here — the figure a person complaining about the app is describing.

Innermost, telemetry answers the other question. It would file one record per transport
attempt, so three retries would be three records and a cache hit would be none, which is
what a request-rate or error-budget dashboard wants. Under the current order a cache hit is
indistinguishable from a very fast remote answer except by costing under a millisecond. If
telling them apart matters, the fix is a second instance of the decorator inside the cache —
not a `cacheHit` flag threaded through `UserRepository`, which describes profile operations
and not how they were served.

## Retry: the policy split

`UserRepository` has three operations over two HTTP methods that differ in what a repeated
call costs, so there are two policies.

| Operation | Method | Attempts | Retries |
| --- | --- | --- | --- |
| `fetchCurrentUser` | `GET` | 3 | any transient failure, plus this type's own deadline |
| `deleteAccount` | `DELETE` | 3 | same — `DELETE` is idempotent |
| `updateProfile` | `PATCH` + key | 3 | same — the key is what makes it converge too |

The third row is the decision finding 7 said had nowhere to live, and it has moved once
since. A `PATCH` whose response was lost may have been applied: the request reached the
server, the server acted, and the reply died on the way back. Until Phase 9 item 5 the only
safe answer was to retry nothing but `URLError` codes that fail while the connection is
still being established — `.notConnectedToInternet`, `.cannotFindHost`,
`.cannotConnectToHost`, `.dnsLookupFailed` — where no byte of the request has been written
to a socket. Deliberately outside that set, because none of them is evidence of anything:

- `.timedOut` and `.networkConnectionLost` — the connection existed.
- `TimedOutError` from the per-attempt deadline — weaker still: the deadline is the client's
  opinion about how long is too long.
- `503`, `504`, `429` — the server answered, so it received the request. Whether it acted
  before answering is not something a status code says.

Item 5 removed the question rather than answering it better. `updateProfile` now carries a
client-generated `Idempotency-Key`, minted once per logical edit and passed unchanged to
every attempt, so the server collapses a duplicate and the client no longer has to infer
whether the write landed — see [`docs/idempotency.md`](./idempotency.md). That is what
`defaultKeyedWritePolicy` spends, and it is a claim about the server:
`defaultUnkeyedWritePolicy` is the classification above, kept intact and still under test,
for an API that ignores the header.

One duplicate stays outside both policies. `URLSessionAPIClient` re-sends a request once on
a 401 to retry it with a refreshed token, which this decorator sees as a single call. The
key covers it, because the re-send copies the original request's headers.

One composition detail is worth stating because it is invisible until it bites:
`Retry.isTransient` was written before anything called `withTimeout`, so it does not know
`TimedOutError` and — like every type it does not recognise — classifies it as not worth
retrying. `RetryingUserRepository.isRetryableIdempotent` is `Retry.isTransient` plus that
one case. Without it, adding a per-attempt deadline would make the first slow attempt
terminal and quietly disable retrying for exactly the failure retrying exists to absorb.

## Cache: what it is, and what it is not

This package already has a cache: `UserPersistenceService`, the SwiftData copy of the
signed-in user, with `SyncStrategy` deciding when it answers and when the API does
([`docs/sync-strategy.md`](./sync-strategy.md)). It is durable, it survives launches, its
window is five minutes, and it is policy.

`CachingUserRepository` is neither durable nor policy. It is a five-second de-duplication
window: three screens reading the profile during one navigation transition produce one
request, and concurrent readers of a cold cache produce one request rather than one each.

The relationship between the two numbers is load-bearing, and
`cacheTimeToLiveIsWellInsideTheSyncWindow` pins it. If the memo ever outlived the strategy's
window, the failure would be silent: `CacheFirstSyncStrategy` would decide its window had
expired, go to the API for a fresh value, and be answered out of the memo.

Two properties keep the window honest even inside it:

- **Failures are never memoised.** `SingleFlightCache` caches successful loads only. An
  offline read fails now and fails again on the next call, so nothing here can make an
  offline app look online; the most it can do is answer with a value the API returned less
  than five seconds ago.
- **Writes drop the memo on both paths.** A `PATCH` that failed with a timeout may still
  have been applied, so invalidating only on success would leave the memo authoritative
  about a profile the server has already replaced.

There is no write-through. `updateProfile` returns the server's user and it is discarded,
for a reason about the primitive: `SingleFlightCache` memoises the result of a load it ran,
and every guarantee in it — one load per key, no resurrection of an invalidated entry, no
caching of failures — is stated in terms of loads it owns. A `store(_:for:)` entry point
would widen that contract to serve one decorator; the cost of not having it is one request
after each profile edit.

Expiry lives in `SingleFlightCache.freshValue(for:isFresh:)`, added by this item, rather
than in the cache as a time-to-live. A TTL is only one way for a value to go stale — an
ETag, a version counter and a push notification are three others — and each is knowledge
the caller has. What the actor provides is the part a caller cannot write safely itself: the
staleness check and the drop happen in one uninterrupted stretch of actor execution, so
nothing can fill the slot in between.

## Telemetry: what is recorded, and what must never be

`RepositoryTelemetry.record` is `async` and cannot throw. Async because the interesting
sinks are isolated — this app's own `DiagnosticJournal` lives on `@DiagnosticsActor`, and a
synchronous requirement would force such a sink to hop through an unstructured `Task`, which
`DiagnosticsActor` documents as destroying the one property a journal has, since two `Task`s
racing to the same domain can arrive in either order. Non-throwing because a profile fetch
must not fail on account of being measured.

Failures are recorded as a **bounded label** — `http(503)`, `transport(-1009)`,
`decodingFailed` — and never as `localizedDescription`. That is the rule `DiagnosticRecord`
already states, applied one layer up: a localised description interpolates whatever the
underlying error carried, which for a `URLError` includes the failing URL, query string and
any token in it, and a diagnostic string outlives the process and is routinely attached to a
bug report. `labelsCarryNoErrorMessage` is the pin.

Cancellation is its own outcome rather than a failure. A `URLSession` task stopped by task
cancellation reports `URLError(.cancelled)` rather than `CancellationError`, so both
spellings are matched — a decorator that knew only the latter would file every dismissed
screen as a transport failure.

Levels are a retention decision, not a formatting one: the unified log persists `.error` to
disk and discards `.debug` unless something is streaming. A call that worked is worth
watching live and not worth storing; one that failed is worth having afterwards, in the
sysdiagnose from the user who reported it.

## What this item did not do

- **It did not unify the error vocabulary.** `docs/solid.md` finding 4 expected it to, and
  the two requirements pull in opposite directions: the retry policy classifies by
  `APIError`'s status code and `URLError`'s code, so translating into
  `UserRepositoryError`'s three cases underneath it erases the evidence the policy runs on.
  Translation above the retry layer is fine and needs a target type that can carry a cause —
  a change to the package's error vocabulary, not a wrapper. Finding 4 and
  `SyncErrorMessage` both now say so instead of pointing at this item.
- **It did not move the 401 refresh out of transport.** Finding 7 proposed that, and a
  `UserRepository` decorator is the wrong home: `LiveAuthService` and
  `LiveSocialAuthExchangeService` are `APIClient` callers too, so the refresh would end up
  in one of the several places that need it. A token refresh is a property of the credential
  a request carries, not of the profile operation being retried.
- **It did not decorate the preview graph.** `AppContainer.preview` still binds a bare
  `MockUserRepository`. Wrapping a double in a retry loop and a cache would test the
  decorators, not the previews, and a preview that silently answered from a memo would be
  harder to reason about, not easier.
- **It did not give the chain a total time budget.** `withTimeout` bounds each attempt, so
  three attempts under a fifteen-second deadline are bounded at roughly forty-five seconds
  plus backoff. A budget for the whole sequence is a different combinator and nothing in the
  app currently needs one.
