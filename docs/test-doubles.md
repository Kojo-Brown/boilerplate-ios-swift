# Test doubles: protocol fakes for the network and the store

Every collaborator between a view model and the outside world is behind a
`Sendable` protocol with a hand-written double beside the live implementation —
fifteen of them, tabulated in [solid.md](./solid.md). That table has been true
since Phase 8. What was not true is the sentence the same page writes
underneath it:

> The doubles in this repo are not mocks generated from the protocol; they are
> hand-written types that reimplement the behaviour. That is the right call for
> a boilerplate — a reader can see what a fake is supposed to do — and it is
> also the failure mode: the two implementations of a protocol are two
> independent readings of a contract that is **written down nowhere**.

This page is that contract, for the two seams the spec item names: the network
and the store. It is written down as a test suite rather than as prose, because
prose is what the doubles already had.

## What goes wrong, concretely

`docs/solid.md` finding 3 is the worked example, and it is worth re-reading as a
story about doubles rather than as a story about Liskov.

`SwiftDataUserPersistenceService.save(user:)` called `context.insert`.
`MockUserPersistenceService.save(user:)` assigned into a dictionary keyed by
`user.id`. Saving one user twice therefore left **two rows on device and one
entry under test**, and `fetchCurrentUser()` picks the greatest `createdAt` —
which for two rows with the same (or `nil`) timestamp is `max(by:)`'s
unspecified tie-break. A "save on every launch" caller read back a stable value
in every test and an arbitrary one on a phone.

Nothing failed. Not the unit suite, not the view-model suites, not CI. The two
implementations had been diverging for eight phases, and what eventually found
it was a person reading both files side by side for an audit.

The repair came with a pin, `saveAgreesBetweenImplementations`, which covers
`save` — one method of the nine on that protocol. The other eight were in
exactly the state `save` had been in.

## The shape of the fix

A contract case is **one sentence about the protocol, run once per
implementation**:

```swift
@Test("An edit is visible to the next fetch", arguments: RepositoryUnderContract.allCases)
func updateIsVisibleToTheNextFetch(_ kind: RepositoryUnderContract) async throws {
    let subject = repository(kind, seededWith: makeSeedUser())

    _ = try await subject.updateProfile(name: "Renamed")
    let fetched = try await subject.fetchCurrentUser()

    #expect(fetched.name == "Renamed")
}
```

The case body cannot tell which side it has, and that is the whole mechanism. A
sentence that holds for the double and not for the live implementation fails
here, in the same run, naming the implementation it failed for.

Two files, two seams:

| Seam | Protocol | Live | Double | Contract |
| --- | --- | --- | --- | --- |
| Network | `UserRepository` | `LiveUserRepository` over the real transport | `MockUserRepository` | [`UserRepositoryContractTests.swift`](../Tests/ViewModelTests/UserRepositoryContractTests.swift) |
| Store | `UserPersistenceService` | `SwiftDataUserPersistenceService` | `MockUserPersistenceService` | [`UserPersistenceContractTests.swift`](../Tests/ViewModelTests/UserPersistenceContractTests.swift) |

## The network double is a fake *server*, not a fake client

This is the one design decision on the page, and it is the reason the network
contract means anything.

The obvious way to give `LiveUserRepository` something to talk to is
`MockAPIClient`, which is what almost every other suite in this bundle does. It
is the wrong seam. `LiveUserRepository.fetchCurrentUser()` is one line — it
forwards to `APIClient.send`. Substituting the client replaces *everything
underneath it*: building the `URLRequest`, attaching the bearer token and the
`Idempotency-Key`, re-sending once on a 401, mapping a status code to an
`APIError`, decoding the body. A contract whose "live" half is
`LiveUserRepository` over `MockAPIClient` is two doubles agreeing with each
other, and it reads as evidence.

So [`FakeUserAPI`](../Tests/ViewModelTests/FakeUserAPI.swift) replaces the
server: a `URLProtocol` holding one profile, answering `GET`, `PATCH` and
`DELETE /users/me` with real status codes and real JSON, behind a real
`URLSession` driving a real `URLSessionAPIClient`. Everything between the
repository and the socket is the shipping code. `Tools/assert-test-doubles.py`
rule 7 refuses a network contract file that names `MockAPIClient`, so the cheap
version cannot creep back in.

It holds a **record** rather than a queue of scripted answers, which is what
separates it from `StubURLProtocol` and `AttestationStubURLProtocol`. Those two
exist to assert what went onto the wire, and a queue is right for that. A
contract case has to be able to read back what the case's own earlier call
wrote — "an edit is visible to the next fetch" is not expressible against a
queue — so this one applies the `PATCH` and serves the result to the next `GET`.
It also keeps an `Idempotency-Key` ledger, because a fake that ignored the key
would let `RetryingUserRepository` look correct while double-writing.

The cost is a shared mutable static, for the reason every `URLProtocol` double
here has one: `URLSession` instantiates the protocol class itself, so there is
no instance a test can configure. That makes the suite `.serialized`, and it is
why the divergence pins live in the **same** suite as the contract cases rather
than in a suite of their own — `.serialized` orders cases within a suite, and
Swift Testing runs suites in parallel with each other.

## What the contract does not cover

Stating the limits, because a check trusted beyond its reach is worse than no
check.

- **The row count.** Nothing on `UserPersistenceService` can count rows, so
  "saving twice leaves one row" — finding 3 itself — is observable only *behind*
  the protocol, which is what `saveAgreesBetweenImplementations` reaches through
  `container.mainContext` and the double's `storage` to do. The contract asserts
  the consequence instead: the read after two saves is the second value,
  deterministically.
- **The tie-break between two rows with the same `createdAt`.** Both
  implementations leave it to `max(by:)` over a sequence whose order neither
  specifies. A case asserting either answer would pin an accident.
- **The call counts.** `MockUserPersistenceService` and `MockUserRepository`
  record them; the live implementations cannot. They are a property of the
  double, tested where they are used.
- **The error vocabularies.** `docs/solid.md` finding 4 is still open: the live
  repository throws `APIError` and the double throws `UserRepositoryError`, and
  the two enums have no case in common. The contract is therefore a contract
  about the **success** paths; `repositoryErrorTypesAreDisjoint` is the pin on
  the failure ones, and it asserts the divergence rather than agreement.
- **The isolation.** `MockUserRepository` is a `@MainActor final class` and
  `LiveUserRepository` is an unisolated `struct` — finding 5, also still open,
  which is why both contract suites are `@MainActor`. A concurrency problem the
  live type would have cannot be observed through the double, and no contract
  case can change that. The repair is a change to the double (state in a lock,
  as `MockAPIClient` already does), not to this contract.
- **Thirteen other seams.** `KeychainStoring`, `TokenStoring`,
  `AuthServiceProtocol`, `SyncStrategy` and the rest have doubles and no
  contract. `KeychainStoring` is the one that most deserves the next one:
  `KeychainWrapperTests` is titled "KeychainWrapper unit tests (via
  InMemoryKeychain)" and every assertion in it is about the double, so the live
  Keychain wrapper is covered by nothing at all.

## The divergences, and why each one stands

These are **inverted** tests. Each fails when the divergence it describes is
*repaired*, so the repair and the edit to this page land in one commit. None of
them is a claim that the current behaviour is right.

`Tools/assert-test-doubles.py` checks the list in both directions: a pin that is
deleted fails the audit, and a non-parameterised case that is not on the list
fails it too — because a contract case that quietly stopped running against both
sides looks exactly like a divergence pin.

### `deleteLeavesTheDoubleAnsweringFetches`

`MockUserRepository.deleteAccount()` increments a counter and returns. It holds
no state for the delete to remove, so `fetchCurrentUser()` afterwards is
answered by the profile it still has — while the live repository, against a
server that honoured the `DELETE`, gets a 404.

Any suite that drives a delete-account flow through the double therefore passes
every assertion after the delete without the delete having meant anything.

Not repaired here because the obvious repair runs straight into finding 4: a
double that fails the next fetch has to fail it *with something*, and the live
stack's answer is `APIError.httpError(statusCode: 404, …)`, which is not in
`UserRepositoryError`. Giving the repository one error type is finding 4's
repair and finding 4's item.

### `aNoContentDeleteFailsOnlyAgainstTheLiveStack`

**This is a live defect, found by the contract.** `204 No Content` is the
correct answer to a `DELETE`, and `LiveUserRepository.deleteAccount()` fails
against it.

`deleteAccount` asks for `EmptyResponse`; `URLSessionAPIClient.send` decodes
every response body; an empty body is not valid JSON. So a request that
succeeded arrives as `APIError.decodingFailed`. The behaviour is not news —
`APICrashReportUploader.outcome(for:)` maps `decodingFailed` to `accepted`
precisely because of it and explains why in a doc comment. What was news is that
nothing in this repository could *see* it, because the only double for this seam
returns from `deleteAccount` with no body to decode and no status code to read.

Not repaired in this item. The fix is a transport that can be asked to discard a
body rather than decode an empty one — a new requirement on `APIClient` and a
change to how `APICrashReportUploader` reads success — which is the transport's
change to make deliberately, not a side effect of an item about doubles.

### `anEditAdvancesTheRevisionOnlyLive`

`User.version` is the server's revision counter, and it is what
`UserMergePolicy` orders two copies of a profile by. The live stack returns the
response body, so an accepted edit comes back at a higher revision. The double
derives its answer locally from the value it already held, so an edit comes back
at the same one.

A merge-policy scenario driven through the double therefore never sees a
revision move. This one is **not repairable by making the double more
faithful**: inventing an increment would be the double asserting something about
a server nobody has configured. It is a limit of the seam, and a test about
revision ordering has to drive the fake server.

### `aRedeliveredEditIsOneWrite`

One edit redelivered is one write — see [idempotency.md](./idempotency.md) — and
the two implementations record that in places a shared case cannot reach. The
live side's evidence is on the server: a second delivery of a key it has already
accepted is answered from the ledger and not applied again. The double's
evidence is `updateKeys`, a list inside the double, which exists because a count
cannot express the property (two deliveries of one edit are two entries with the
*same* key; two edits are two entries with different ones).

Both halves are asserted in the one case, because the pair is the claim.

## The audit

`Tools/assert-test-doubles.py` runs in the audits job, on Linux, needing no
toolchain and no simulator. It exists because all four ways a contract stops
working compile, run and report success:

1. **A protocol grows a requirement and no contract case mentions it.** The new
   method is then specified by whichever implementation a test happens to reach,
   which is the state finding 3 came out of. Rule 2 reads the requirements off
   the `protocol` declaration in `Sources/` — not off the extension below it,
   since a method with a default implementation is not a requirement — and fails
   on any that no case calls.
2. **A case loses its `arguments:` and runs against one side.** It still passes
   and still reads as a contract case. Rule 3 requires every `@Test` in a
   contract file to carry `arguments: <Enum>.allCases`, or to be a recorded
   divergence. The attribute is gathered until its parentheses balance, so
   wrapping the arguments over three lines does not evade it.
3. **A divergence pin is deleted.** Rule 4 checks the table in both directions,
   and checks that each pin is described on this page.
4. **The live side stops being live.** Rule 7 refuses `MockAPIClient` in the
   network contract file.

Rules 1, 5 and 6 are the structural floor: the implementations enum still has
exactly its pinned cases, both sides are still declared under the names the
audit pins and are still named by the contract file, and nothing in a contract
file is suppressed with `withKnownIssue`, `.disabled(`, `.bug(` or a
commented-out `@Test`.

Each rule was checked against the defect it names by reintroducing that defect
and watching the audit fail: seven rules, sixteen mutations — fifteen defects,
every one caught, and one legal spelling (a case whose `arguments:` are wrapped
over three lines) that has to keep passing. Three of the first twelve did *not*
fail, and each was the rule's fault rather than the mutation's: a commented-out
enum case still left its name in the file, a renamed enum still matched as a
prefix, and a double mentioned only in a doc comment counted as a double the
contract builds. All three rules read a narrower thing now — the enum's own
body, a word boundary, a construction rather than a mention. The table is in the
pull request that added it.

## Writing the next one

1. Put the contract in `Tests/ViewModelTests/<Protocol>ContractTests.swift` with
   an enum naming the implementations, one case per side.
2. Write each case as one sentence about the protocol, taking the enum as its
   argument. If a case needs to know which side it has, it is not a contract
   case.
3. Build the live side out of the live types. For anything with a transport,
   that means replacing the server and not the client.
4. Record every divergence in `DIVERGENCES` in the audit, pin it with an
   inverted test, and describe it on this page with why it stands and what
   repairing it would take.
5. Add the seam to `CONTRACTS` in the audit, which is what turns rules 1 to 7 on
   for it.
