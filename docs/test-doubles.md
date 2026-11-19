# Test doubles: protocol fakes, and what holds them to the real thing

Phase 12 item 5.

Every seam in this package is a protocol, and most of them have a hand-written
stand-in next to the implementation that ships — `MockAPIClient` beside
`URLSessionAPIClient`, `MockUserPersistenceService` beside
`SwiftDataUserPersistenceService`, and about twenty more. That much was true
before this item. What was not true is that any of them had been *checked*
against the thing it replaces.

That distinction is the whole subject of this page, because a double is not a
convenience. It is a claim: *substituting me changes nothing a caller can
observe.* A test that uses one is evidence about the app only to the extent that
the claim holds, and nothing in a passing test suite distinguishes a double that
behaves like the real implementation from one that behaves plausibly.

## The two ways a double goes wrong, and why neither is red

**It drifts.** Both implementations are written by hand, so the protocol's rules
exist twice. `UserPersistenceService` has nine requirements; before this item
exactly one of them — the `save` upsert, in
`SolidSubstitutabilityTests.saveAgreesBetweenImplementations` — had ever been
compared across the two. The other eight were a matter of having been written
twice and read once. `docs/solid.md` finding 3 is what drift looks like when
someone eventually notices: `save(user:)` inserted on the store and upserted in
the double, so saving twice left two rows on device and one under test, and
every test that used the double was quietly describing a different store.

**It can be scripted into a world that does not exist.** This is the subtler
one and it was `MockAPIClient`'s whole shape. Its `handler` returns `Any`:

```swift
let client = MockAPIClient()
client.handler = { _ in User(email: "a@example.invalid", name: "A") }
```

The test author writes the *outcome* directly, so nothing stops them writing one
the transport cannot produce — a decoded `User` for a request the server
answered 500 to, an `APIError.unauthorized` where `URLSessionAPIClient` throws
`httpError`, an `httpError` carrying status 204. The caller is then tested
against a server that cannot exist, and the test passes, and it will go on
passing after the caller breaks against the real one.

Neither failure is a red build. Both are a green suite measuring the wrong
thing, which is the only reason any of the machinery below is worth its weight.

## What holds them: a differential contract suite

`Tests/ViewModelTests/NetworkDoubleContractTests.swift` and
`Tests/ViewModelTests/PersistenceDoubleContractTests.swift` are one table of
scenarios each, run twice — once against the live implementation, once against
the double — asserting the same outcomes of both.

Three rules make them worth reading:

1. **Everything goes through the protocol.** No assertion reaches for
   `MockUserPersistenceService.storage` or executes a `FetchDescriptor`. A
   contract is what a *caller* can observe, and a caller holds the protocol.
   That is also what lets one case body run unchanged against both halves.
   Where an existing test could only establish a fact by counting rows, the
   contract suite finds a way to ask the same question through the seam — the
   upsert is observed by deleting once and looking again, because a store that
   inserted twice still holds a row afterwards.

2. **The expectation is written out, not derived.** Each scenario names the
   outcome both implementations owe a caller, and the suite asserts *three*
   things: live matches it, the double matches it, and the two match each other.
   Asserting only that the two agree would be satisfied by two implementations
   that are wrong in the same way.

3. **Both halves run and are named.** `@Test(arguments: StoreKind.allCases)`
   rather than a `for` loop over the two, so the report says which half failed.
   A loop reports one failure for the pair and stops at the first, which is the
   wrong shape when the interesting outcome is "the live store does this and the
   double does that".

## The network double has two modes, and the choice matters

`MockAPIClient` can now be armed two ways.

```swift
// Outcomes. The test is about the caller; the response is scenery.
client.handler = { _ in user }

// The wire. The test is about what the caller does with a server's answer.
client.script([
    MockAPIClient.Exchange(statusCode: 500),
])
```

`script(_:)` takes `(statusCode, body)` and resolves it by calling
`APIResponseValidation` — **the same functions `URLSessionAPIClient` calls**.
That is the repair for the second failure mode above: a scripted double cannot
express an answer the real transport would not produce, because it is not
deciding the mapping, it is reading the one decision there is.

Reach for `handler` when the response is incidental — a view model's loading
states, a decorator's retry counting, a sync strategy's choice of source. Reach
for `script(_:)` the moment the test's subject is *a server's answer*.

Extracting the mapping is why the contract suite is not circular. If the double
reimplemented the `switch`, the suite would be asserting that a copy of the
logic agrees with the logic. Sharing it means agreement is structural, and the
suite's remaining job is the parts that cannot be shared: the decoder, the body,
and the one path the double deliberately does not model.

### The path the double does not model

A 401 on an authenticated endpoint sends the transport to `/auth/refresh` and
then re-sends the original request, so one `send` is three exchanges on the
wire. The double does not do that, and should not: replacing the client means
the client's retry is the thing being replaced, and a double that reimplemented
it would be asserting a copy against the original again.

`theRefreshRetryIsNotModelledByTheDouble` pins that divergence rather than
leaving it to be discovered — live returns the row, the double throws
`unauthorized`, and the test says so. What it costs is written down: a test that
needs the refresh-and-retry uses `URLSessionAPIClient` over a `URLProtocol`
stub, as `APIClientTests` and `IdempotencyTransportTests` do. A test that
scripts `.unauthorized` on the double is testing what a caller sees once the
refresh has already failed. The two converge again at
`aPersistent401IsUnauthorized`: once the retry is spent, both answer alike.

### A finding the suite surfaced, left unfixed

`send` decodes every 2xx body, so **a 2xx carrying no body at all is
`APIError.decodingFailed`** on both implementations: an empty `Data` is not
valid JSON, and `EmptyResponse` needs at least `{}`.

This was already known in one place — `APICrashReportUploader` maps
`decodingFailed` to `.accepted` and its test calls that "the normal path for
this endpoint, not a defensive branch" — but it is not accommodated everywhere
it bites. `LiveUserRepository.deleteAccount()` decodes `EmptyResponse`, so
against a server that answers a conforming `204 No Content` with no body, it
throws `decodingFailed` rather than succeeding.

The contract suite pins the current behaviour (the scenario named *200 carrying
nothing at all*) rather than changing it. Teaching the transport to read an
empty success body as `{}` is a change to what the app does, not to how its
doubles are tested, and it deserves its own item with its own argument. Pinning
it means that item will start from a test that says what the behaviour is today.

## What the gate checks

`Tools/assert-test-doubles.py`, in the audits job. It needs no toolchain, so it
is one of the few gates the scheduled agent can run on Linux before pushing.

A contract suite protects nothing if the arrangement around it quietly changes,
and every way it can is a one-line edit that leaves the build green:

| What the gate catches | Why a green run does not |
| --- | --- |
| A third conformer of an audited protocol with no registry row | The suite goes on testing the two it knows about; the new type is substituted with nothing saying it behaves like the original |
| A registry row whose type is gone or renamed | The row becomes a claim about a type that does not exist — an allowlist nobody prunes is a rubber stamp |
| A suite that no longer names the double registered to it | The tests still there still pass |
| A registered suite that is missing, or holds no `@Test` | Same |
| `200...299` re-inlined into the transport or the double | **The contract suite cannot see this one.** Both halves go on agreeing with whichever copy each of them reads |
| Either file no longer calling `APIResponseValidation` | Same |

Each of those seven was checked against the defect it names before the step was
added to CI.

The audited set is the two seams this item covers — `APIClient` and
`UserPersistenceService`. It is a registry rather than a sweep of every
`Mock*`/`Stub*`/`InMemory*` type on purpose: most of this package's doubles
stand in for a service with no second implementation to be differential
against. There is no live `BarcodeScanning` to compare
`MockBarcodeScannerService` to without a camera, and a gate demanding a contract
suite for one would be demanding a suite that cannot be written.

## Adding a seam to the audited set

1. Write the contract suite first. If you cannot say what a caller observes
   through the protocol, there is no contract to hold the double to, and the
   honest outcome is a note here rather than a row in the registry.
2. Decide where a shared decision has to live. The network seam needed
   `APIResponseValidation` extracted before its double could be held to
   anything; a seam whose rules are all in the protocol's requirements may need
   nothing.
3. Add the protocol to `REGISTRY` in `Tools/assert-test-doubles.py` with every
   conformer, each as `live`, `double` or `decorator`, and the suite that holds
   each double.
4. Run `python3 Tools/assert-test-doubles.py`. Then break it on purpose — rename
   the double, empty the suite — and check it fails. A gate nobody has seen fail
   is a gate nobody knows works.

## See also

- `docs/testing.md` — which framework a suite can fail in, and the three ways a
  test here can silently stop being able to fail.
- `docs/solid.md` — the audited surface, the four findings about these doubles,
  and which are repaired.
- `docs/dependency-injection.md` — how the composition root binds the live graph
  and the preview container binds the doubles.
