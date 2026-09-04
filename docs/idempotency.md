# Idempotent sync requests with client-generated keys

Phase 9 item 5: `updateProfile` sends an `Idempotency-Key` the server can recognise a
repeat by, and the retry policy over it is widened to spend that.

Three earlier items wrote down the gap this closes, each from its own side.
`RetryingUserRepository` said a retry budget for a lost `PATCH` "needs an idempotency key
that lets the server collapse a duplicate". `Retry`'s documentation said the same about
its own loop. `SyncStrategy` said an offline write needs "somewhere to queue and a rule
for reconciling it on the way back" — item 3 supplied the rule, and this item supplies the
half of the queue that is about safety rather than storage.

## The problem, stated exactly

A `PATCH` that fails with a timeout has three possible histories and the client cannot
tell them apart:

1. The request never arrived.
2. It arrived and was rejected.
3. It arrived, was applied, and the response died on the way back.

Retrying is right for (1) and (2) and wrong for (3), and the failure carries no
information about which one happened. Everything the retry layer did before this item was
an attempt to work around that: the write policy retried only `URLError` codes that fail
while the connection is still being *established* — `.notConnectedToInternet`,
`.cannotFindHost`, `.cannotConnectToHost`, `.dnsLookupFailed` — because those are the only
failures that prove no byte of the request reached a socket. A timeout, a lost connection,
a 503: all refused, because each of them is compatible with history (3).

That is the safe answer to the wrong question. The client cannot know whether the write
happened; the server can. A key moves the decision to the side that has the information.

## The mechanism

`IdempotencyKey` is a v4 UUID minted on the device and sent in the `Idempotency-Key`
header. The server records the key alongside the outcome of the first request that carried
it; a later request with the same key is answered from that record instead of being
executed. The client stops having to infer whether a write landed, so it can retry the
failures that say nothing.

It is **client**-generated for a reason that is not stylistic: the key has to exist before
the first attempt, because the attempt whose answer is lost may be the first one. A
server-assigned identifier arrives in a response the client may never see.

## Where it is minted, and why exactly there

```
ProfileEffectHandler
  └─ SyncStrategy.updateProfile(name:)          ← policy: where the write goes
       └─ UserRepository.updateProfile(name:)   ← MINT: one key per logical edit
            └─ TelemetryUserRepository          ← forwards
                 └─ CachingUserRepository       ← forwards
                      └─ RetryingUserRepository ← reuses across attempts
                           └─ LiveUserRepository
                                └─ URLSessionAPIClient  ← header; reuses on the 401 re-send
```

The mint point is `UserRepository`'s protocol *extension* — `updateProfile(name:)`, the
overload without a key — and everything below it takes the key as a parameter. Two
properties fall out of that placement:

- **One call is one key.** A person who taps Save twice has asked for two writes and gets
  two keys. Collapsing those would be a bug of the opposite kind.
- **One key is every attempt.** `RetryingUserRepository` captures the key it was handed and
  passes the same one to each attempt. A key re-minted per attempt costs a header and buys
  nothing while reading as though duplicates were handled — which is why the mint point is
  an extension rather than a protocol requirement: a conformer cannot override it and
  quietly re-mint mid-chain.

## What it bought: the widened write policy

| Operation | Method | Attempts | Retries |
| --- | --- | --- | --- |
| `fetchCurrentUser` | `GET` | 3 | any transient failure, plus the per-attempt deadline |
| `deleteAccount` | `DELETE` | 3 | same — `DELETE` converges on the same state |
| `updateProfile` | `PATCH` + key | 3 | same — the key is what makes it converge too |

`RetryingUserRepository.defaultKeyedWritePolicy` is now identical to the read policy, and
that identity *is* the result: with a key on the request, a keyed write is exactly as
repeatable as a read.

**This is a claim about the server, and it is the only one this package makes.** If the API
ignores the header, the widened policy is a double-write waiting for a slow afternoon.
`defaultUnkeyedWritePolicy` — the old classification, unchanged and still under test — is
there for that case, and selecting it is one argument at the composition root:

```swift
RetryingUserRepository(
    base: LiveUserRepository(client: apiClient),
    writePolicy: RetryingUserRepository.defaultUnkeyedWritePolicy
)
```

## The duplicate no policy could see

`URLSessionAPIClient` re-sends a request once on a 401, after refreshing the token. That is
a second delivery produced *below* every retry policy in the package —
`RetryingUserRepository` sees one call — and a 401 arriving after the server acted is not
exotic: an access token that expires between the request being authorised and the response
being written produces exactly it.

Nothing can make that re-send safe on its own. What the client does is not throw away the
thing that makes it recognisable: the retry copies the original `URLRequest` and replaces
only `Authorization`, so the key set on the first delivery is still on the second. Pin:
`theRefreshRetryResendsTheSameKey`, which asserts both `PATCH`es carry one key and that the
second carries the refreshed token.

This is the part of the mechanism that pays off even under the unkeyed policy.

## Why the write takes a key and the other two operations do not

`fetchCurrentUser` is a `GET`; there is no duplicate to collapse, and `APIEndpoint` refuses
a key on a safe method with a precondition — at best it is noise in the server's log, at
worst a cache-key mismatch in a proxy that varies on request headers.

`deleteAccount` is a `DELETE` against a resource that either exists or does not, so
repeating it converges without help; that is why the read policy already covers it. A key
would change the *status code* a duplicate sees, from a 404 to the original 204. That is
worth something one day and is not worth a parameter on the protocol today.

## Validation, and why the adopting initialiser is failable

`IdempotencyKey(rawValue:)` rejects an empty string, anything over 255 characters, and
anything outside RFC 3986's unreserved set (`A–Z a–z 0–9 - . _ ~`). The value goes into a
header verbatim, so a string carrying CR/LF would let whoever supplied it append headers of
their own to the request. The narrowing past "legal in a header" is because a key is
usually echoed into a log line, a URL and a database key on the server, and the set that is
safe in all three is smaller than the set HTTP permits. `IdempotencyKey()` — the generated
form, and the only one production uses — cannot produce a rejected value.

## What is not done

**There is still no outbox.** A key lives in memory for the duration of a call, which
covers every retry inside one process: the loop in `RetryingUserRepository`, and the 401
re-send below it. It does not cover an edit that outlives the process. An offline write
that queues, survives a relaunch and replays later needs the key written down *beside the
pending edit* — a persisted row, a new schema version and a migration (see
[`docs/migrations.md`](./migrations.md)), and a replay coordinator with a rule for when it
gives up. Item 3 supplied the merge rule such a queue needs on the way back
([`docs/conflict-resolution.md`](./conflict-resolution.md)) and this item supplies the
replay safety; the storage is still ahead, and `updateProfile` still fails rather than
queueing when the device is offline.

**Nothing sends a version as a precondition.** A key stops the *same* edit being applied
twice; it does nothing about two different edits racing. That is `If-Match` and a 409, and
`docs/conflict-resolution.md` records it as its own item.

**No server-side half is included.** This is an iOS boilerplate; the record of
key → outcome, its retention window, and what the server does when the same key arrives
with a *different* body are the API's to implement. The last of those is the one worth
agreeing on early: the conventional answer is a 422, and this client would surface it as a
non-retryable `APIError.httpError`.
