# Conflict resolution: a version field and a merge policy

Phase 9 item 3. What happens when the row on this device and the response from
the API both claim to describe the same profile, which of them wins, and the
three things this item deliberately did not build.

## The bug it fixes

Phase 9 item 1 made SwiftData the source of truth. Read
[`docs/offline-first.md`](./offline-first.md) and the inversion is the whole
story: the read starts at the store, the stamp on the row decides whether a
request happens, and the value handed back after a refresh is the row.

Except on the write into that row, which looked like this:

```swift
let fetched = try await repository.fetchCurrentUser()
let persisted = try await persist(fetched, at: instant)   // unconditional
```

That line is correct for `remoteOnly`, `remoteFirst` and `cacheFirst`, because
under those three the API *is* the truth and the row is a copy of its last
answer — a copy has no standing to refuse. It is wrong for the one policy that
says the row is authoritative. Under `offlineFirst` a response and a row are two
claims about one profile, and nothing in the package compared them: the response
won by arriving.

The failure that produces is not hypothetical and not loud. A read replica that
has not caught up, a request retried against a different node, a background
refresh racing the foreground one it was scheduled beside — any of them hands
back a copy of an *older* write. The old code wrote it over the row and then
stamped the row as confirmed, so the profile rolled back and the freshness
window suppressed the next request that would have corrected it.

## The version field

`User.version` is an `Int?`: the server's revision counter for the profile,
carried on the row as `UserEntity.version` so it survives a launch.

The obvious alternative is already there — `updatedAt` — and it is the fallback
rather than the rule, because it is a wall-clock instant minted by whichever
machine performed the write. This package has already written down what a wall
clock does to a comparison: `StoredUser.isFresh(at:maxAge:)` treats a row
stamped in its own future as stale, precisely because clocks move. A skewed
freshness stamp costs one unnecessary request. A skewed *merge* costs the newer
write, permanently and silently.

A counter the server increments per accepted write has none of that. It needs no
clock, it cannot go backwards unless the server says so, and equality means "the
same write" rather than "within the same second".

**It is optional, and `nil` is not zero.** The field is a claim about the
server: an endpoint that does not report a revision decodes to `nil`, and every
row written before this item has `nil` in the column. If `nil` read as revision
zero, the first response from a deployment that stopped reporting the field
would lose every comparison against a versioned row, and the profile would
freeze on disk. `absentRevisionIsNotVersionZero` pins that it does not.

## The merge policy

`UserMergePolicy` has one requirement — `decide(local:remote:)` — and
`LastWriterWinsMergePolicy` is the implementation the app resolves. The rules,
in the order they are applied:

| # | Condition | Decision | Writes? |
| --- | --- | --- | --- |
| 1 | no stored row | `noLocalCopy` | yes |
| 2 | the stored row is a different user | `differentIdentity` | yes |
| 3 | both carry a revision, remote's is higher | `remoteWinsOnVersion` | yes |
| 3 | both carry a revision, stored's is higher | `localWinsOnVersion` | **no** |
| 3 | both carry the same revision | `sameVersion` | yes |
| 4 | no revision pair; remote's `updatedAt` is later | `remoteWinsOnTimestamp` | yes |
| 4 | no revision pair; stored's `updatedAt` is later | `localWinsOnTimestamp` | **no** |
| 4 | no revision pair; the timestamps are equal | `sameTimestamp` | yes |
| 5 | neither pair exists | `unordered` | yes |

Three of those rows are worth arguing rather than reading.

**Rule 2 is not a conflict.** Nothing clears the store on sign-out yet — the gap
[`docs/offline-first.md`](./offline-first.md) lists and does not close — so the
row the store calls "current" can belong to the previous account. A merge is a
question about two copies of *one* profile, and two different people are not
that question.

**Rule 5 accepts.** A policy that refused to write whenever it could not prove
the response was newer would leave an unversioned, untimestamped profile frozen
on disk forever. That is a worse failure than the clobber it avoids, and a
quieter one, so the floor is the behaviour this package had before the policy
existed. The decision says which rule fired, so a caller can tell an ordered
merge from a guess.

**The decision is one value, not a `Bool` and a reason.** `MergeDecision` is a
flat enum whose `acceptsRemote` is spelled out case by case rather than through
a `default`, so a new decision cannot be added without answering the question
the caller acts on. `exactlyTwoDecisionsReject` pins that exactly two of the
nine refuse.

## A read falls back; a write fails

The same policy runs on both paths of `OfflineFirstSyncStrategy`, and the two do
different things with a rejection. That asymmetry is the one design decision in
this item that could reasonably have gone the other way.

**A read that rejects the response returns the row**, with
`origin == .localCache` — the same shape as an offline read, because it is the
same situation: the network was asked and had nothing better to offer. The row
is then re-persisted rather than merely returned, which restamps it. Without
that, a server that is behind would be re-asked on *every* read for as long as
it stayed behind; the write is an upsert of the value already on disk, so
nothing but the stamp changes.

**A write that rejects the response throws** `MergeConflictError`, carrying both
revisions. A read has the row to hand back and a write does not: the caller
asked for a change, and a server answering with a revision older than the one on
disk has not applied that change to the profile the caller was looking at.
Returning the row would report success for a write that did not happen.
Returning the response would roll the profile back in order to satisfy a request
that was meant to move it forward. Failing is the only true answer available.

Only `offlineFirst` consults a policy. The other three strategies are unchanged
and take no `mergePolicy` argument, because under them the response is
authoritative by definition — there is no second claim for a rule to arbitrate
between, and giving them one would be a policy that always returns
`noLocalCopy`.

## The schema change

`UserEntity` gained one optional attribute, which is the same cheapest-possible
shape `refreshedAt` used in Phase 9 item 1: SwiftData's implicit lightweight
migration adds it to an existing store with no migration plan and fills it with
`nil` — exactly what a row written before this item should say.

The honest caveat is also the same one, and it is now two columns deep: neither
`refreshedAt` nor `version` is covered by a `VersionedSchema`. Phase 9 item 4 is
where they get one, and this column is the second thing it will have to migrate
from.

## Where the pins are

| Claim | Test |
| --- | --- |
| The nine decisions | `LastWriterWinsMergePolicyTests` |
| An absent revision is not revision zero | `absentRevisionIsNotVersionZero` |
| Exactly two decisions reject | `exactlyTwoDecisionsReject` |
| The revision decodes from the API payload | `revisionDecodesFromJSON` |
| A stale response does not overwrite the row | `staleResponseDoesNotOverwriteTheRow` |
| A rejected response still restamps the row | `aRejectedResponseStillRestampsTheRow` |
| A newer revision wins and lands on the row | `aNewerRevisionWinsAndLandsOnTheRow` |
| The strategy consults the policy | `theStrategyAsksThePolicy` |
| A stale write fails | `aWriteWhoseResponseIsOlderFails` |
| …carrying both revisions | `theConflictErrorCarriesBothRevisions` |
| The revision survives SwiftData | `UserEntityVersionTests` |

## What this item did not do

- **It does not merge fields.** The winner is a whole `User`. A name edited on
  this device is lost when the server's copy wins, and nothing tells the person
  it happened. Field-level merging needs per-field provenance — which field
  changed, and when — and this app has one writer per profile, so the value that
  would carry that does not exist yet.
- **It does not send the version back on a write.** The revision is read,
  stored and compared; it is not attached to the `PATCH` as a precondition, so
  the *server* cannot reject a stale edit — only this device can reject a stale
  response. Doing it properly means an `If-Match` header or a version in
  `UpdateProfileRequest`, a 409 in the error vocabulary, and a decision about
  what the UI does with one. That is a change to `UserRepository`'s contract and
  to every decorator around it, which is its own item rather than a paragraph in
  this one.
- **There is still no outbox.** An edit made offline still fails rather than
  queueing. This item supplied the merge rule that a queue would need on the way
  back; the queue itself, and the client-generated keys that make a replayed
  request idempotent, are the next item in this phase.
- **Nothing surfaces a conflict to the person.** `MergeConflictError` reaches a
  screen as a `SyncErrorMessage` like any other failure. "Someone else changed
  this — keep yours or take theirs" is a UI, and it needs the field-level merge
  above to have anything to offer.
