# Dependency injection

`AppContainer` is this package's composition root: the one place that decides
which implementation of anything runs. This page is why it looks the way it
does — including the two shapes it deliberately is not.

Everything here is pinned by
[`AppContainerTests`](../Tests/ViewModelTests/AppContainerTests.swift) and by the
two container tests in
[`SolidContractTests`](../Tests/ViewModelTests/SolidContractTests.swift).

## What it replaces

[`docs/solid.md`](./solid.md) finding 1: there was no composition root. There
were ten initialisers, each of which knew how to build its own collaborator and
did so from a default argument:

```swift
init(client: any APIClient = URLSessionAPIClient.shared,
     tokenStore: TokenStore = .shared) { ... }
```

and every view started one of those chains from a `@State` property:

```swift
@State private var viewModel = LoginViewModel()
```

which resolved, entirely through defaults, to a five-hop graph — `LoginViewModel`
→ `LiveAuthService` → `URLSessionAPIClient.shared` → `TokenStore.shared` →
`KeychainWrapper` — that was written down nowhere.

The defaults were not there by accident: they made the types testable, and they
worked. What they could not do is answer "what runs in the app?" in one place.
Every test passed a double explicitly, so every test exercised the injected path
and nothing exercised the default path — and the default path is the one that
shipped.

Today none of those initialisers has a default argument. `AppContainer.live()`
is the only function in the package that names a live implementation.

## The shape: a struct of existentials

```swift
struct AppContainer: Sendable {
    let apiClient: any APIClient
    let tokenStore: any TokenStoring
    let keychain: any KeychainStoring
    let userRepository: any UserRepository
    let authService: any AuthServiceProtocol
    let socialAuthProvider: any SocialAuthProvider
    let socialAuthExchange: any SocialAuthExchangeService
    let biometricAuth: any BiometricAuthProvider
    let textRecognizer: any TextRecognizing
    let barcodeScanner: any BarcodeScanning
    let makeCameraService: @Sendable () -> CameraService
}
```

Eleven stored properties, every one of them an abstraction, and a memberwise
initialiser the compiler writes. `live()` and `preview` are the two graphs;
adding a third (a UI-test graph, a demo graph) is another static.

### Why not a registry

"DI container" usually means a service locator: `register(SomeProtocol.self) {
… }` into a dictionary keyed by type, `resolve()` back out. That is
deliberately not what this is.

A dictionary has to answer *what if nothing is registered?*, and every answer is
worse than the question:

- **Trap.** `resolve()` calls `fatalError` on a miss. The app now has a crash
  whose cause is a missing line in a setup function, discovered at the moment
  the screen is opened rather than at the moment the line is deleted.
- **Return an optional.** Every call site unwraps, and the unwrap has no good
  branch — a view model with no auth service cannot do anything useful.
- **Fall back to a default.** This is finding 1 again, one indirection further
  away and harder to see.

Stored properties turn that runtime question into a compile error, raised at the
only place that can answer it. Deleting a line from `live()` does not fail on
launch; it fails on build.

The cost is real: adding a collaborator means editing `AppContainer`, so it is
closed to extension in the open/closed sense. For an application with one
composition root that is the right trade — the registry buys extensibility
nobody needs by paying in a failure class that only exists at runtime. A library
shipped to unknown consumers would weigh it differently.

### Why not `@Environment`

SwiftUI's own answer to prop-drilling is the environment, and `AppState` and
`AppCoordinator` are already passed that way. The container is not, because
`EnvironmentKey` requires a `defaultValue`:

```swift
private struct ContainerKey: EnvironmentKey {
    static let defaultValue = AppContainer.live()   // ← the finding, restored
}
```

A view that is never handed a container would silently get one anyway. Whichever
value goes in that slot is wrong: `.live()` reintroduces the invisible default
that finding 1 is about, and `.preview` ships fakes to anyone who forgets a
modifier.

So the container is threaded by initialiser, from `BoilerplateApp` down:

```
BoilerplateApp → RootView → AppNavigationView → HomeView
                          → LoginView         → TextRecognitionView
                                              → BarcodeScannerView
```

Six views take a `container:` argument, and forgetting to pass one is a build
error.

## Views and view models

A view never names a collaborator. It asks the container for the view model it
owns:

```swift
struct LoginView: View {
    @State private var viewModel: LoginViewModel

    init(container: AppContainer) {
        _viewModel = State(wrappedValue: container.makeLoginViewModel())
    }
}
```

`State(wrappedValue:)` rather than a stored default. SwiftUI keeps the value
produced by the first initialisation of a given view identity and discards the
rest, so a re-init driven by a parent's body evaluation costs an allocation and
does not reset the screen. That allocation is why `CameraService` is worth a
sentence: constructing one allocates an `AVCaptureSession` and a preview layer
and touches no hardware — nothing is configured or started until `start()`.

Two views in the tree — `RootView` and `AppNavigationView` — spell their
initialisers out by hand. They have to: a `private` stored property (their
`@Environment` values) makes the synthesised memberwise initialiser private too,
and both are constructed from another file.

## Lifetimes

The container makes three lifetime decisions that used to be side effects of
where a default argument happened to sit.

| Collaborator | Lifetime | Why |
| --- | --- | --- |
| `TokenStore` | one per graph | The refresh coalescing in `refreshIfNeeded(using:)` only works if the transport and both auth services hold the *same* actor. That was previously true because all three defaulted to `.shared`. |
| `URLSessionAPIClient` | one per graph | A `struct`, so "shared" means shared configuration; it matters because a decorator wrapped around it in `live()` (Phase 8 item 4) wraps every caller at once. |
| `CameraService` | one per screen | Both camera view models used to default to `CameraService()`, giving each its own `AVCaptureSession` by accident. The factory states the choice, and `cameraFactoryVendsAFreshServicePerCall` pins it. |

## `TokenStoring`

`docs/solid.md` finding 2: `TokenStore` was depended on as a concrete `actor`.
It is now behind a protocol with four requirements — `currentToken()`,
`setTokens(_:)`, `clearTokens()`, `refreshIfNeeded(using:)` — which is every
member anything outside it calls. `accessToken` and `refreshToken` stay off the
protocol; they are read by the actor's own methods and nothing else.

Every requirement is `async`, because the live conformer is an actor: a
synchronous, non-throwing actor method witnesses an `async throws` requirement
without ceremony, while a synchronous *requirement* would force the witness to
be `nonisolated`, which is the opposite of what the type is for.

The double, `InMemoryTokenStore`, is also an `actor` — matching the live type's
isolation on purpose, because finding 5 is what happens when a double's
isolation differs from its implementation's. It does **not** coalesce
concurrent refreshes, and that divergence is recorded rather than hidden: the
coalescing is the behaviour worth testing against the real store, and a double
that reimplemented it would be a second, unreviewed copy of the subtlest code in
the networking layer. `refreshCount` is exposed so a test that cares can assert
on the calls instead.

## What is deliberately not in the container

- ~~**`UserPersistenceService`.**~~ It was, until Phase 8 item 3 gave it a
  caller. The `ModelContext` objection did not survive that: the store is
  `@MainActor`, a main-actor class is `Sendable`, and every requirement on
  `UserPersistenceService` is `async`, so a nonisolated strategy reaches it with
  a plain `await` and the context never crosses an isolation boundary.
  `BoilerplateApp` opens the `ModelContainer` and passes the store into
  `live(userStore:)`, which has no default argument on purpose — a composition
  root that opens a disk-backed store as a side effect of a default is finding 1
  wearing a different hat. See [`docs/sync-strategy.md`](./sync-strategy.md).
- **A protocol for `CameraService`.** Finding 2 lists it as unabstracted and
  argues it should stay that way: it wraps `AVCaptureSession`, its
  `previewLayer` is an `AVCaptureVideoPreviewLayer` on either side of a
  protocol, and `DelegateStreamTests` already drives it directly on a simulator
  with no capture device. What it needed from the root was the lifetime
  decision, not an abstraction, so it is vended as a factory.
- **`AppState` and `AppCoordinator`.** View state, not collaborators. They stay
  in the SwiftUI environment where they were.
- **`JSONDecoder`, `JSONEncoder`, `URLSession`.** Configuration rather than
  collaborators: none appears in the audited surface, substituting one changes
  how a request is encoded rather than who answers it, and they keep their
  defaults on `URLSessionAPIClient.init`.

## What is not pinned

- **Nothing stops a new default argument.** A collaborator added tomorrow with
  `= LiveThing()` on its initialiser would rebuild finding 1 next to the
  container, and no test in this repo fails. The container tests assert what
  `live()` binds, not that nothing else could bind anything.
- **`live()` is constructed in tests but never exercised.** `KeychainWrapper`
  and `GoogleSignInService` are built and their types asserted; no test drives a
  request through the live graph, which would need a network and a signed-in
  Google account. The store is the exception — `live()` is handed one backed by
  `PersistenceController.makeInMemoryContainer()`, and the strategy suites drive
  the real `SwiftDataUserPersistenceService` through it.
- **View construction is checked, view rendering is not.**
  `PreviewProviderTests` instantiates each screen with `.preview` and stops
  there, because the test target has no SwiftUI host to evaluate a body in.
