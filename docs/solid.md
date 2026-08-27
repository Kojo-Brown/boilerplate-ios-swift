# SOLID in the repository and service layers

An audit of the types the app's data flows through — or, as it turns out, mostly does not.
For each SOLID principle: what it asks of this layer, where the code answers, where it does
not, and which later Phase 8 item is the fix for the gap.

Every structural claim on this page is pinned by
[`SolidContractTests`](../Tests/ViewModelTests/SolidContractTests.swift). Some of those pins
are compile-time — a conformance stated as `let x: any Abstraction = Concrete()` cannot
silently go away — and some are differential tests that run a live implementation and its
test double through the same script and assert they disagree. The second kind fails when a
finding is **fixed**, which is the point: a repair cannot quietly leave this page describing
a problem that is gone.

Findings 1 and 2 are **fixed** as of Phase 8 item 2, finding 6 as of Phase 8 item 3, finding
7 as of Phase 8 item 4, and finding 3 as of Phase 9 item 1. Their sections have been
rewritten to say what replaced them rather than left describing a problem that is gone — see
[`docs/dependency-injection.md`](./dependency-injection.md),
[`docs/sync-strategy.md`](./sync-strategy.md),
[`docs/decorators.md`](./decorators.md) and
[`docs/offline-first.md`](./offline-first.md) for the four designs. Findings 4, 5 and 8 still
stand, and each names the item that is its fix — except finding 4, which named item 4 and no
longer does: that item is done and deliberately did not take it on, for a reason recorded in
its section below.

## The surface that was audited

Everything that sits between a view model and the outside world — network, Keychain, disk,
camera, identity providers. Twelve types carry that role, and the audit is the whole set.

| Collaborator | Abstraction | Live implementation | Double | Constructed in production by |
| --- | --- | --- | --- | --- |
| HTTP transport | `APIClient` | `URLSessionAPIClient` | `MockAPIClient` | `AppContainer.live()` |
| User data | `UserRepository` | `LiveUserRepository` | `MockUserRepository` | `AppContainer.live()` |
| Local store | `UserPersistenceService` | `SwiftDataUserPersistenceService` | `MockUserPersistenceService` | `AppContainer.live()` |
| Password login | `AuthServiceProtocol` | `LiveAuthService` | `MockAuthService` | `AppContainer.live()` |
| Social identity | `SocialAuthProvider` | `GoogleSignInService` | `MockSocialAuthProvider` | `AppContainer.live()` |
| Social identity | `SocialAuthProvider` | `AppleSignInService` | — | **nothing** |
| Credential exchange | `SocialAuthExchangeService` | `LiveSocialAuthExchangeService` | `MockSocialAuthExchangeService` | `AppContainer.live()` |
| Biometrics | `BiometricAuthProvider` | `LiveBiometricAuthService` | `MockBiometricAuthService` | `AppContainer.live()` |
| Text recognition | `TextRecognizing` | `LiveTextRecognitionService` | `MockTextRecognitionService` | `AppContainer.live()` |
| Barcode scanning | `BarcodeScanning` | `LiveBarcodeScannerService` | `MockBarcodeScannerService` | `AppContainer.live()` |
| Keychain | `KeychainStoring` | `KeychainWrapper` | `InMemoryKeychain` | `AppContainer.live()` |
| Token state | `TokenStoring` | `TokenStore` | `InMemoryTokenStore` | `AppContainer.live()` |
| Camera session | **none — a concrete `class`** | `CameraService` | — | `AppContainer.makeCameraService` |
| Read policy | `SyncStrategy` | `RemoteOnly` / `RemoteFirst` / `CacheFirst` / `OfflineFirst` | `MockSyncStrategy` | `AppContainer.live()` |
| Policy resolution | `SyncStrategyFactory` | `LiveSyncStrategyFactory` | `MockSyncStrategyFactory` | `AppContainer.live()` |

Fourteen of the fifteen now get the shape right: a `Sendable` protocol, one live conformer
(four, for `SyncStrategy` — that is the Strategy pattern rather than a divergence), a
hand-written double, and — since Phase 7 — a double whose mutable state lives inside a lock
rather than under `@unchecked Sendable`. The fifteenth, `CameraService`, is unabstracted on
purpose; finding 2 below says why.

The last two rows arrived with Phase 8 item 3 and are the reason the `UserPersistenceService`
row's right-hand column changed: the store was constructed by nothing because nothing read
it, and a policy object is something that reads it.

The right-hand column is the part item 2 changed. It used to read "default arguments only",
"`LoginViewModel` default", "`.shared`, via defaults" — twelve rows and no two of them
naming the same place.

## Dependency inversion

### Finding 1 — the composition root is a pile of default arguments — **fixed**

*Fixed by Phase 8 item 2 (PR #33). The description below is what was found; the repair
follows it.*

There was no composition root. Every type in the table above knew how to build its own
collaborator, spelled as a default argument on its initialiser:

```swift
init(client: any APIClient = URLSessionAPIClient.shared,
     tokenStore: TokenStore = .shared) { ... }
```

and every view started one of those chains from a `@State` property:

```swift
@State private var viewModel = LoginViewModel()
```

which resolved, entirely through defaults, to:

```
LoginView → LoginViewModel() → LiveAuthService() → URLSessionAPIClient.shared
          → TokenStore.shared → KeychainWrapper()
```

Five construction decisions, none of them written down anywhere, each taken by the type that
happened to sit one level above. The high-level policy (`LoginViewModel`) did not depend on
an abstraction here so much as it depended on an abstraction *and also knew the concrete
type to reach for when nobody said otherwise* — which is the half of the D that matters,
because it is the half that decides what runs in the app.

The defaults were why this was invisible in the test suite: every test passes a double
explicitly, so every test exercised the injected path and nothing exercised the default
path. The default path is the one that ships.

This was never an argument that the code was untestable — it very much was, and that is what
the defaults were for. It was an argument that "which implementation runs" was a property of
ten scattered initialisers rather than of one place a reader can look at.

**Repair.** `AppContainer` is that place. Ten initialisers lost their default arguments,
`URLSessionAPIClient.shared` and `TokenStore.shared` are gone, and the container is threaded
from `BoilerplateApp` down the view tree by initialiser — not through `@Environment`, whose
mandatory `defaultValue` would have rebuilt the finding one indirection away.
[`docs/dependency-injection.md`](./dependency-injection.md) has the design and the two
shapes it rejected.

**Pin:** was `zeroArgumentConstructionStillCompiles`, which constructed six types with no
arguments at all and which this page predicted would stop compiling when the defaults came
off. It did, and it was rewritten rather than relaxed — none of those six expressions is
spellable now. `liveContainerBindsTheLiveGraph` and `previewContainerBindsTheDoubles`
replace it, asserting the dynamic type behind each of the container's ten collaborators;
`AppContainerTests` covers the behaviour those bindings are supposed to produce.

### Finding 2 — two collaborators have no abstraction at all — **fixed for one, declined for the other**

`TokenStore` and `CameraService` were depended upon as concrete types.

`TokenStore` was the consequential one. `URLSessionAPIClient`, `LiveAuthService`
and `LiveSocialAuthExchangeService` all stored `private let tokenStore: TokenStore` — the
actor itself, not an existential. It was not unreachable in a test, because it takes an
injectable `any KeychainStoring`, but the seam sat one level lower than the one a caller
wants: a test that needed "a store that reports the token as expired" had to build a fake
Keychain and populate it, rather than passing a fake store. The refresh-coalescing logic in
`refreshIfNeeded(using:)` is the most subtle code in the networking layer and the only way
to substitute it was to not use it.

**Repair.** `TokenStoring` — four requirements, all `async`, which is every member anything
outside the actor calls. All three collaborators now hold `any TokenStoring`, and
`InMemoryTokenStore` is the double, itself an `actor` so that substituting it does not
change isolation the way finding 5 describes. `TokenStoringSeamTests` is the suite that
could not have been written before: it substitutes the store itself to assert that an
authenticated request fails at the store rather than at the network, and that a request with
no token throws instead of attempting a refresh.

`CameraService` is the declined one, and the reason is the same one this page gave for
calling it defensible. It is a `final class` wrapping `AVCaptureSession`, and
`Tests/ViewModelTests/DelegateStreamTests.swift` already exercises it directly on a
simulator that has no capture device — so the parts that can be pinned without hardware
already are. Extracting a protocol would buy a substitutable preview layer and little else,
and `previewLayer` is an `AVCaptureVideoPreviewLayer` either way. What it did need from the
composition root was the *lifetime* decision, which was previously a side effect of two
view-model default arguments both spelling `CameraService()`: the container vends it through
a `@Sendable () -> CameraService` factory, one session per screen, pinned by
`cameraFactoryVendsAFreshServicePerCall`.

## Liskov substitution

The doubles in this repo are not mocks generated from the protocol; they are hand-written
types that reimplement the behaviour. That is the right call for a boilerplate — a reader
can see what a fake is supposed to do — and it is also the failure mode: the two
implementations of a protocol are two independent readings of a contract that is written
down nowhere.

Two divergences are live today.

### Finding 3 — `save(user:)` means different things in the store and in its double

> **Repaired in Phase 9 item 1.** Both implementations upsert. The reasoning and
> the new pin are at the end of this section; the description below is kept in
> the past tense because it is what the audit found and what the repair had to
> answer.

`SwiftDataUserPersistenceService.save(user:)` inserted:

```swift
context.insert(user.toEntity())
```

`MockUserPersistenceService.save(user:)` upserts:

```swift
storage[user.id] = user
```

Saving the same `User` twice therefore leaves **two rows** in the real store and **one entry**
in the double. `UserEntity.id` deliberately carries no `@Attribute(.unique)` — the comment on
it explains why, and the reason is sound — so nothing in the store collapses the duplicate.

The consequence is not hypothetical. `fetchCurrentUser()` returns the row with the greatest
`createdAt`, and `createdAt` is optional and treated as `.distantPast` when absent. Two rows
for the same user, both with a `nil` `createdAt`, are ordered by `max(by:)`'s unspecified
tie-break — so a "save on every launch" caller reads back a stable value in tests and an
arbitrary one on device. The existing suite never notices because no test in it saves the
same user twice.

Which of the two is correct is a design question this audit does not answer: an upsert is
probably what a single-signed-in-user store wants, but making it so is a change to the
store, not to the double, and it belongs with the offline-first item in Phase 9 that will
give this store an actual caller.

**The repair (Phase 9 item 1).** The upsert won, for the reason the audit guessed it would
and one it could not have: the store holds the signed-in user, so a second row for one `id`
is a duplicate rather than a record — and `OfflineFirstSyncStrategy` *answers reads from
the row*, so the arbitrary tie-break the finding described stopped being a value read back
and became the value on screen. `UserEntity.id` still carries no `@Attribute(.unique)`,
because the constraint traps on an in-memory store and that is every store the tests and
previews run on; uniqueness is enforced by the write instead.

`update(user:)` was repaired in the same change and for the same reason. It assigned
`name`, `avatarURL` and `updatedAt` and left `email` and `createdAt` on whatever the row
already held — survivable while the API could correct the copy on the next read, and not
survivable once the row *is* the answer. It now writes every mapped field.

**Pin:** `saveAgreesBetweenImplementations` asserts one row against one entry, and
`UserPersistenceTests.saveTwiceLeavesOneRow` and `updatePreservesTheStamp` cover the store
directly. The suite's rule still holds in the other direction: a differential test fails
when the divergence it describes is repaired, which is what made this page and the code
change together.

### Finding 4 — the two `UserRepository` implementations throw disjoint error types

`UserRepositoryError` — `.notFound`, `.unauthorized`, `.networkUnavailable`, with localized
descriptions written for a user to read — is thrown by exactly one type in this package, and
it is the mock. `LiveUserRepository` forwards to `APIClient`, so what actually comes out of
it in production is `APIError`: `.unauthorized`, `.httpError(statusCode:data:)`,
`.decodingFailed`, `.networkUnavailable(URLError)`.

So a caller written as

```swift
} catch let error as UserRepositoryError {
```

handles every failure the tests can produce and none that the app can. The reverse is also
true: nothing translates a 404 into `.notFound`, so that case is unreachable from any code
path that touches the network. `Tests/ViewModelTests/UserRepositoryTests.swift` asserts
`UserRepositoryError` handling throughout, which is why this reads as covered.

The protocol is silent on all of this, and Swift's `throws` gives it nowhere to speak: an
untyped `throws` is a contract that says only "something may go wrong". Typed throws
(`throws(UserRepositoryError)`) exist in Swift 6 and would state it, at the cost of making
the live implementation do the mapping the mock currently pretends is already happening.

**Fix:** not a Phase 8 item — it is a change to `UserRepository` itself. Item 4 was named as
the natural moment for it, on the reasoning that once decorators sat between the client and
the repository, something would have to decide which layer owned error translation. That
item is done and the answer turned out to be "not a decorator", which is worth recording
here rather than moving the expectation to the next item along:

`RetryingUserRepository` decides whether a failure is worth another attempt by reading
`APIError.httpError`'s status code and `URLError`'s code — a 503 is retryable, a 400 is not,
and a `.notConnectedToInternet` is the one class of failure a non-idempotent write may be
retried through. A translation into `UserRepositoryError`'s three cases placed *underneath*
that policy erases exactly the evidence it runs on; placed *above* it, translation is fine
and useful, but it then needs a target type that can carry a cause, and inventing that type
is a change to this package's error vocabulary rather than a wrapper around its repository.
The two things pull in opposite directions and the item that fixes this has to say which
side of the retry policy it lands on. See [`docs/decorators.md`](./decorators.md).

**Pin:** `repositoryErrorTypesAreDisjoint` drives both implementations into failure and
asserts each throws its own type.

### Finding 5 — the double is main-actor isolated and the live type is not

`LiveUserRepository` is a `struct` with no isolation; `MockUserRepository` is a `@MainActor
final class`. Substituting the double therefore changes where the work runs. Nothing is
unsound — the protocol is `Sendable` and both satisfy it — but a test using the double can
never observe a concurrency problem the live type would have, because the double serialises
everything onto one actor.

The mock is a class for a real reason (it counts calls, and a struct cannot), and `@MainActor`
is the cheapest way to make a mutable class `Sendable`. The alternative the rest of the
package already uses — state inside an `OSAllocatedUnfairLock`, as in `MockAPIClient` and
`MockAuthService` — keeps the call counts and drops the isolation difference. That is a
small, self-contained repair and it is the one this finding recommends.

**Pin:** `makeLiveRepositoryOffTheMainActor()` is a `nonisolated` function that constructs a
`LiveUserRepository`. It compiles only while the live type is *not* actor-isolated, so the
tempting fix — annotating `LiveUserRepository` with `@MainActor` so the two agree — breaks
the build here instead of passing silently.

## Single responsibility

### Finding 6 — the repository layer is not on any data path — **fixed**

*Fixed by Phase 8 item 3 (PR #34). The description below is what was found; the repair
follows it.*

This is the finding that reframes the rest of the page.

No view model holds a `UserRepository`. No view model holds a `UserPersistenceService`.
`BoilerplateApp` builds a `ModelContainer` and installs it in the environment, and nothing
reads it — there is no `@Query` and no `modelContext` access anywhere in `Sources`. The
screen that displays a list gets it from here:

```swift
private func fetchItems() async throws -> [HomeItem] {
    try await Task.sleep(for: .milliseconds(600))
    return (1...10).map { HomeItem(id: UUID(), title: "Item \($0)", ...) }
}
```

`HomeViewModel` fabricates its own data, in a private method, with a sleep standing in for
latency. `HomeItem` is a separate type from `User` and does not come from any wire model.

*Amended by Phase 8 item 2.* This finding used to open with "`LiveUserRepository` and
`SwiftDataUserPersistenceService` are never constructed outside the test target", and half
of that is no longer true: `AppContainer.live()` constructs a `LiveUserRepository`, so the
repository is now built in production and still read by nobody. That is a smaller gap than
it was and the same gap in kind — a layer with a constructor is not a layer with a caller.
`SwiftDataUserPersistenceService` is not in the container at all, because it needs a
non-`Sendable` `ModelContext` and wiring a store with no caller would mean inventing one.

Everything above about substitutability and inversion is therefore, for these two types, a
statement about code with no callers. That is worth saying plainly rather than burying: a
repository layer nothing routes through is not wrong, it is *unevaluated*. The Interface
Segregation section below is where this bites hardest.

The auth path is the exception and the counter-example: `LoginView` → `LoginViewModel` →
`LiveAuthService` → `URLSessionAPIClient` → `TokenStore` → `KeychainWrapper` is a complete
chain from a view to the Keychain, and every hop in it goes through a protocol. The shape
this repo wants already exists; it exists once.

**Repair.** `SyncStrategy` is the caller. `ProfileViewModel` holds one, `SettingsView`
holds the view model, and the chain `SettingsView` → `ProfileViewModel` → `SyncStrategy` →
`UserRepository` → `APIClient`, with a second leg into `UserPersistenceService`, is
complete and goes through a protocol at every hop. `BoilerplateApp` now builds the
`ModelContainer` first and hands its `mainContext` to a `SwiftDataUserPersistenceService`
that `AppContainer.live()` takes as an argument, so the container that used to be installed
and never read is on a data path. The design, and the four things the item deliberately did
not do, are in [`docs/sync-strategy.md`](./sync-strategy.md).

Two parts of the finding are **not** repaired and should not be read as covered.
`HomeViewModel` still fabricates its list with a `Task.sleep`; that is a separate gap and it
needs a list endpoint, not a policy. And Phase 9 item 1 is still ahead — this item makes the
store a cache the API writes to, not the source of truth.

**Pin:** `liveContainerBindsTheLiveGraph` now asserts thirteen bindings rather than ten, and
`SwiftDataUserPersistenceService` is one of them. `ProfileFeatureTests` drives the caller
(it was `ProfileViewModelTests` until Phase 8 item 6 replaced the view model with a `Store` —
see [`docs/unidirectional-data-flow.md`](./unidirectional-data-flow.md)).
The direction this finding could regress in — the caller being deleted — fails there and in
`SettingsView`'s initialiser, which no longer compiles without a container.

### Finding 7 — `URLSessionAPIClient.performRequest` carries five responsibilities — **fixed**

*Fixed by Phase 8 item 4 (PR #35). The description below is what was found; the repair
follows it.*

One private method builds the URL, attaches the bearer token, performs the transport,
detects a 401, drives a token refresh, retries the original request with a new token, and
validates the status code. The retry-on-401 policy is not a decision any caller can make —
it is welded to the only `APIClient` the app has.

The cost is visible from the other end of the package. `Sources/Core/Concurrency/Retry.swift`
and `Timeout.swift` shipped in Phase 7 with a full backoff schedule and jitter, and the spec
records that **nothing calls either combinator**, because "wiring in a policy is a decision
about which endpoints are idempotent" — and there is nowhere to express that decision.
Adding caching, telemetry, or a retry budget today means editing `URLSessionAPIClient`,
which is the open/closed principle failing for the same structural reason.

**Fix:** Phase 8 item 4, "Decorator pattern: repository wrappers adding cache, retry, and
telemetry". `APIClient` has exactly one requirement and is already the right shape to wrap;
a `RetryingAPIClient(wrapping:)` is a dozen lines once something composes it, and the 401
refresh becomes one decorator among several rather than a permanent feature of transport.

**Repair.** Three decorators — `RetryingUserRepository`, `CachingUserRepository`,
`TelemetryUserRepository` — composed in that order inside `AppContainer.live()`, so
`Retry`, `Backoff` and `withTimeout` have a production caller for the first time and adding
a fourth behaviour is a line in the composition root rather than an edit to transport. The
policy this finding said had nowhere to live now has a name and a seam: reads and
`deleteAccount` retry any transient failure, and `updateProfile` retries only failures that
prove the request was never delivered, because a `PATCH` whose response was lost may have
been applied. [`docs/decorators.md`](./decorators.md) is the design.

The item's own title says "repository wrappers", and that is where these went — the
decorators wrap `UserRepository`, not `APIClient`. Two consequences follow and neither is
hidden:

- **The 401 refresh is still in `URLSessionAPIClient`, by choice rather than by omission.**
  This finding proposed moving it out. Moving it into a `UserRepository` decorator would put
  it in exactly one of the several places that need it — `LiveAuthService` and
  `LiveSocialAuthExchangeService` are `APIClient` callers too — and a token refresh is a
  property of the credential a request carries, not of the profile operation being retried.
  Splitting `performRequest` further is a transport change and a separate item; what this
  finding got wrong was calling every one of the five responsibilities a decorator's job.
- **`performRequest` is down one responsibility, not five.** The retry *policy* is no longer
  welded in, which is the open/closed half of the finding. Building the URL, attaching the
  token, refreshing it and validating the status are still in the same method.

**Pin:** `decoratorChainIsTelemetryOverCacheOverRetry` walks
`AppContainer.live().userRepository` through `UserRepositoryDecorator.base` and asserts all
four names in order, so a reordering — which changes what the telemetry measures and what
the cache costs — fails rather than passing quietly.
`liveContainerBindsTheLiveGraph` asserts the outermost name alongside the other twelve
bindings. `retryUsesTheCombinatorsThatHadNoCaller` is the direct pin on the sentence this
finding turns on: it fails if the retry loop stops being reached.

### Finding 8 — `AppleSignInService` is dead, and the view model reimplements it

`AppleSignInService` is 124 lines that conform to `SocialAuthProvider`, bridge
`ASAuthorizationController`'s delegate callbacks into `async`/`await`, generate a nonce, and
SHA-256 it. Nothing references it. The only occurrence of its name outside its own file is a
doc comment in `CancellableContinuation.swift`.

The Apple flow instead lives in `SocialLoginViewModel`, which carries its own
`prepareAppleNonce()`, its own `generateNonce(length:)` and its own `sha256(_:)` — the last
two byte-for-byte identical to the private statics in `AppleSignInService`, down to the
charset string and the 16-byte `SecRandomCopyBytes` loop. The view model also unpacks
`ASAuthorizationAppleIDCredential` itself, which is the other thing the service exists to do.

So the two Apple implementations are a duplicated security primitive, and the one that is
tested through the `SocialAuthProvider` seam is the one that never runs. Google goes through
the protocol; Apple does not, because `SignInWithAppleButton` wants to own its request and
hands the result back to the view, and the provider protocol's
`signIn(anchor:) async throws` shape does not fit that. That is a real API constraint and not
an oversight — but it argues for deleting the unused service or reshaping the protocol to
admit both flows, not for keeping both and letting the nonce logic drift.

**Fix:** not currently a spec item. The smallest honest repair is to delete
`AppleSignInService` and move the nonce helpers to one shared place; the larger one is a
`SocialAuthProvider` that can express a button-driven flow.

**Pin:** the audit list includes `AppleSignInService` as an `any SocialAuthProvider`, so the
conformance cannot be dropped without this page being revisited — deleting the type is a
deliberate act that fails the build here first.

## Interface segregation

There is no fat interface in this layer. `APIClient`, `TextRecognizing`, `BarcodeScanning`,
`SocialAuthProvider`, `SocialAuthExchangeService` and `AuthServiceProtocol` have one
requirement each; `BiometricAuthProvider` has three, all of which its single consumer uses;
`KeychainStoring` has four and `TokenStore` uses all four. `TokenStoring`, added by Phase 8
item 2, has four as well, and they are exactly the four members anything outside the actor
calls — `accessToken` and `refreshToken` stayed off it for that reason, which is ISP
answered at the moment the interface was written rather than audited afterwards.

`UserPersistenceService` has five requirements and `UserRepository` has three, and until
Phase 8 item 3 neither had a client — so ISP could not be evaluated against them at all,
the principle being about what a client is forced to depend on. It can now, and the answer
is that both are honest: the strategies call `fetchCurrentUser()` and `updateProfile(name:)`
on the repository and leave `deleteAccount()` to a caller that wants it, and they reach the
store through `update`, `save` and `fetchCurrentUser` — three of five, with `delete` and
`deleteAll` belonging to a sign-out path that does not exist yet. Nothing is forced to
depend on a member it does not use; nothing yet justifies splitting either protocol.

The one interface worth a note is the opposite problem:

```swift
@MainActor
protocol ViewModelProtocol: AnyObject {
    func onAppear() async
    func onDisappear()
}

extension ViewModelProtocol {
    func onAppear() async {}
    func onDisappear() {}
}
```

Both requirements have default implementations, so conforming to `ViewModelProtocol` demands
nothing — a type with an empty body satisfies it. Nothing is ever held as `any
ViewModelProtocol`; the views hold their view models concretely, so the protocol is not
dispatched through either. It is a naming convention that the compiler has been asked to
witness. That is not harmful, but it should not be read as a contract, and two of the six
view models (`SocialLoginViewModel`, `BiometricAuthViewModel`) do not adopt it at all.

**Fix:** Phase 8 item 6, "Unidirectional data flow: single `State` + `Action` + `Effect`
contract per feature", is the item that replaces it with something that constrains.

**Pin:** `emptyConformanceSatisfiesViewModelProtocol` declares a class with an empty body
that conforms. Giving the protocol a requirement without a default breaks it.

## Open/closed

Reported as observations rather than findings, because nothing here is currently costing
anything.

**Where it holds.** `APIEndpoint` is extended by static factories rather than by cases in a
switch, so a new endpoint touches no existing code. `LoadingState`, `FieldUpdate` and `Route`
are closed enums extended through their operations. `Retry` and `Backoff` are
free functions over a policy value. `Sources/Core/Concurrency` is, throughout, the part of
this package that gets this right.

`AppEvent` was in that list as a fourth closed enum and is no longer an enum at all. Phase 8
item 5 made it a protocol, which moves it from "closed and extended through its operations"
to open outright: a new event is a new type, and adding one is a file, not an edit to a type
two features already depend on. The reason it was worth changing is on the other side of the
bus — a single enum forced every subscriber to receive every case and `switch` back to the
one it wanted, so the closure that read well here was paid for at each consumer. See
[`docs/events.md`](./events.md).

**Where it does not.** Finding 7 was the open/closed failure that mattered: behaviour was
added to the network layer by editing it. Since Phase 8 item 4 the data layer takes a new
behaviour as a wrapper and a line in `AppContainer.live()`, and the remaining edit-to-extend
surface is transport itself — a sixth thing `performRequest` must do is still a change to
`performRequest`. `HTTPMethod` is a closed enum with five cases and no
`.head`, `.options` or `.trace`, which is a real limit and an entirely reasonable one for a
JSON API boilerplate.

## What the pin does not cover

Stating the limits, because a check that is trusted beyond its reach is worse than no check.

- **It is keyed on names.** A collaborator introduced under a name the audit does not list —
  `…DataSource`, `…Client`, `…Store` — is invisible to `SolidContractTests` and needs this
  page revisited by hand. There is no reflection over the module's type list to fall back on;
  Swift has no equivalent of reading the compiled output the way this repo's Android sibling
  does in its own `SolidContractTest`.
- **"Nothing reads this in production" was never pinned.** Finding 6 was the most important
  one on the page and the one a test could not hold: nothing failed when a new caller
  appeared, which is the direction the change came from. Now that the caller exists the
  asymmetry is reversed and still only half-covered — `ProfileFeatureTests` and
  `liveContainerBindsTheLiveGraph` fail if the wiring is removed, but no test would notice a
  *second* layer being added and left unread.
- **Nothing stops a new default argument.** The container tests assert what
  `AppContainer.live()` binds, not that no other type could bind anything. A collaborator
  added tomorrow with `= LiveThing()` on its initialiser would rebuild finding 1 beside the
  container and no test here would fail.
- **Nothing reads the telemetry.** `decoratorChainIsTelemetryOverCacheOverRetry` asserts
  that `OSLogRepositoryTelemetry` is in the live graph and the decorator suite asserts what
  a sink is handed, but no test observes the unified log, so a `Logger` misconfigured into
  silence would pass everything here. The seam is the mitigation: the sink is a protocol,
  and every claim about *what* is recorded is made against the recording double.
- **The freshness window is the one piece of policy with no compile-time home.**
  `CacheFirstSyncStrategy`'s `maxAge` is a `Duration` with a default on
  `LiveSyncStrategyFactory`; nothing fails if it is set to a value that makes the cache
  useless or permanent. `docs/sync-strategy.md` says what the default is for.
- **The camera view models are now in a pin, but a shallow one.**
  `cameraViewModelsUseTheFactoriesService` builds both and compares their preview layers,
  which is enough to show each got its own service and nothing about capture, because the
  suite still touches no hardware.
- **Nothing here checks that the doc and the code agree in prose.** The pins assert
  structure. The paragraphs are still paragraphs.

## Where these findings go

| Finding | Principle | Fixed by |
| --- | --- | --- |
| 1 — defaults are the composition root | DIP | **fixed** — Phase 8 item 2, `AppContainer` |
| 2 — `TokenStore` unabstracted | DIP | **fixed** — Phase 8 item 2, `TokenStoring` |
| 2 — `CameraService` unabstracted | DIP | **declined** — vended as a factory, reasons above |
| 3 — `save` diverges from its double | LSP | **fixed** — Phase 9 item 1, both upsert |
| 4 — disjoint error types | LSP | no item — needs an error type, not a decorator (above) |
| 5 — double is `@MainActor`, live type is not | LSP | self-contained; lock instead of actor |
| 6 — the layer has no callers | SRP | **fixed** — Phase 8 item 3, `SyncStrategy` |
| 7 — transport carries the retry policy | SRP / OCP | **fixed** — Phase 8 item 4, decorators |
| 8 — dead `AppleSignInService`, duplicated nonce | SRP | not currently a spec item |
