import Foundation

// MARK: - AppContainer

/// The composition root: the one place that decides which implementation of
/// anything runs.
///
/// `docs/solid.md` finding 1 is what this replaces. There was no composition
/// root — there were ten initialisers, each of which knew how to build its own
/// collaborator and did so from a default argument, so `LoginView()` resolved a
/// five-hop chain (`LoginViewModel` → `LiveAuthService` → `URLSessionAPIClient`
/// → `TokenStore` → `KeychainWrapper`) that was written down nowhere. Every test
/// passed a double explicitly, so the tests exercised the injected path and
/// nothing exercised the default path — which is the one that shipped.
///
/// Now every one of those initialisers requires its collaborator, and this type
/// is the only thing in the package that names a live implementation. Deleting
/// a line from `live()` is a build failure, not a silent fallback.
///
/// ## Why a struct of existentials, and not a registry
///
/// The service-locator shape — `register(SomeProtocol.self) { ... }` into a
/// dictionary, `resolve()` back out — is what "DI container" usually means, and
/// it is deliberately not what this is. A dictionary keyed by type has to answer
/// "what if nothing is registered?", and every answer is bad: trap at runtime,
/// return an optional every call site must unwrap, or fall back to a default —
/// which is finding 1 again, one indirection further away. Stored properties
/// make the same question a compile error at the only place that can fix it.
///
/// The cost is real and worth stating: adding a collaborator means editing this
/// type, so it is closed to extension in the open/closed sense. For an app with
/// one composition root that is the right trade — the alternative buys
/// extensibility no one needs with a class of failure that only appears at
/// runtime.
///
/// ## What is deliberately absent
///
/// Nothing in the audited surface, as of Phase 8 item 3. `UserPersistenceService`
/// used to be the exception and is now a stored property — see `userStore` for
/// why the `ModelContext` objection did not survive the item that gave the
/// store a caller.
///
/// ## How it reaches a view
///
/// By initialiser, down the view tree from `BoilerplateApp`. `@Environment`
/// was the obvious alternative and was rejected: `EnvironmentKey` requires a
/// `defaultValue`, so a view that is never handed a container silently gets one
/// anyway — an invisible default resolving to a concrete graph, which is the
/// exact shape of the finding this type exists to remove. Threading it by hand
/// costs six `container:` arguments and makes forgetting one a build error.
struct AppContainer: Sendable {

    // MARK: - Collaborators

    /// HTTP transport. Everything that talks to the API goes through this one
    /// instance, so a decorator wrapped around it here (Phase 8 item 4) is
    /// wrapped around every caller at once.
    let apiClient: any APIClient

    /// Token lifecycle. Shared by reference with `apiClient` and both auth
    /// services: a refresh triggered by one is seen by all three, which is the
    /// whole point of `TokenStore`'s coalescing and was previously guaranteed
    /// only by everybody happening to default to the same singleton.
    let tokenStore: any TokenStoring

    /// Secure storage backing `tokenStore`. Held here as well so that a caller
    /// wanting to clear credentials on sign-out has something to ask.
    let keychain: any KeychainStoring

    /// The announcing half of the app's event bus.
    ///
    /// Two properties for one object, on purpose. `EventPublishing` and
    /// `EventSubscribing` are separate protocols because nothing in the app does
    /// both, and binding them separately here is what carries that split down to
    /// the call sites: a view model is handed `eventPublisher` and cannot
    /// subscribe, `SessionObserver` is handed `eventSubscriber` and cannot
    /// announce. `live()` and `preview` both pass the same `EventBus` to both,
    /// which is the property that makes a publication reach a subscriber at all.
    let eventPublisher: any EventPublishing

    /// The listening half of the same bus. See `eventPublisher`.
    let eventSubscriber: any EventSubscribing

    /// User-profile data operations against the API.
    ///
    /// Not a bare `LiveUserRepository` since Phase 8 item 4: it is the outermost
    /// link of a decorator chain, and `live()` below is where the chain and its
    /// order are decided. `docs/decorators.md` says why the order is what it is.
    let userRepository: any UserRepository

    /// The local copy of the signed-in user.
    ///
    /// This used to be the entry in "what is deliberately absent": it needs a
    /// `ModelContext`, which is not `Sendable`, and wiring a store with no
    /// caller would have meant inventing one. Phase 8 item 3 is the item that
    /// gave it a caller, so it is here now. The isolation question the earlier
    /// note deferred has a small answer: `SwiftDataUserPersistenceService` is
    /// `@MainActor`, a main-actor class is `Sendable`, and every requirement on
    /// `UserPersistenceService` is `async`, so a nonisolated strategy reaches
    /// it with a plain `await` and the `ModelContext` never crosses anything.
    let userStore: any UserPersistenceService

    /// Builds a `SyncStrategy` for a policy. Held alongside the resolved
    /// strategy below, not instead of it: the root decides the app's default,
    /// and a caller with a reason to depart from it — a refresh gesture that
    /// must not be answered by a fresh cache — asks for the policy it needs
    /// rather than for a type it would have to name.
    let syncStrategyFactory: any SyncStrategyFactory

    /// The app's declared read policy, resolved once, here.
    ///
    /// This is the Strategy half of Phase 8 item 3. Changing how every profile
    /// read in the app behaves is the `syncPolicy:` argument to `live()` and
    /// nothing else — no view model, no repository and no transport has an
    /// opinion about caching.
    let syncStrategy: any SyncStrategy

    /// Email/password sign-in.
    let authService: any AuthServiceProtocol

    /// Google sign-in. Apple's flow is driven by `SignInWithAppleButton` and
    /// does not go through this seam — `docs/solid.md` finding 8.
    let socialAuthProvider: any SocialAuthProvider

    /// Exchanges a social credential for app-issued tokens.
    let socialAuthExchange: any SocialAuthExchangeService

    /// Face ID / Touch ID evaluation.
    let biometricAuth: any BiometricAuthProvider

    /// Vision-backed text recognition.
    let textRecognizer: any TextRecognizing

    /// Vision-backed barcode and QR scanning.
    let barcodeScanner: any BarcodeScanning

    /// A factory, not an instance — and not a protocol either.
    ///
    /// `docs/solid.md` finding 2 lists `CameraService` as unabstracted and then
    /// argues it should stay that way: it is a `final class` wrapping
    /// `AVCaptureSession`, its `previewLayer` is an
    /// `AVCaptureVideoPreviewLayer` whichever side of a protocol it sits on, and
    /// `DelegateStreamTests` already drives it directly on a simulator with no
    /// capture device. A protocol here would buy a substitutable preview layer
    /// and nothing else.
    ///
    /// What it does need from the composition root is the *lifetime* decision.
    /// Both camera screens used to default to `CameraService()`, which gave each
    /// its own session by accident rather than by choice. A factory states the
    /// choice — one session per screen — and leaves a shared one a one-line
    /// change here.
    let makeCameraService: @Sendable () -> CameraService
}

// MARK: - The live graph

extension AppContainer {
    /// Where the app's requests go when nobody says otherwise.
    ///
    /// This was `URLSessionAPIClient.shared`'s hardcoded string. It is a
    /// placeholder host, deliberately not a real one, and it is a default on
    /// the composition root — which is one place to look — rather than a
    /// default on a type that transport happens to construct.
    ///
    /// It sits outside the `@MainActor` extension below so that reading it does
    /// not require the main actor; an immutable `Sendable` static needs no
    /// isolation to be safe.
    static let defaultBaseURL = URL(string: "https://api.example.com/v1")!

    /// The unified-log subsystem the app's telemetry is filed under.
    ///
    /// A placeholder in the same spirit as `defaultBaseURL`, and deliberately
    /// not `Bundle.main.bundleIdentifier`: an app built from this template
    /// should say what its logs are called here, in the composition root, where
    /// the rest of its wiring is — not inherit it from whatever bundle the code
    /// happens to be running in, which for the test bundle is not the app.
    static let logSubsystem = "com.example.boilerplate-ios-swift"
}

/// `@MainActor` because `GoogleSignInService` is: it drives `GIDSignIn`, whose
/// picker is UIKit-presented, so the type is main-actor isolated and cannot be
/// constructed anywhere else. That is a constraint the graph inherits rather
/// than a preference — everything else in `live()` is nonisolated — and it
/// costs nothing in practice, because the only caller is app startup.
@MainActor
extension AppContainer {

    /// The graph the app runs on.
    ///
    /// Read top to bottom, this is the whole answer to "what actually runs?".
    /// `keychain`, `tokenStore` and `apiClient` are bound to locals first
    /// because the rest of the graph shares them: `LiveAuthService` and
    /// `LiveSocialAuthExchangeService` must write tokens that
    /// `URLSessionAPIClient` will later read, and that is true here because one
    /// `TokenStore` is passed to all three, not because three initialisers
    /// defaulted to the same static.
    ///
    /// `userStore` has no default. Building one needs a `ModelContext`, and a
    /// composition root that opens a disk-backed SwiftData container as a
    /// side effect of a default argument is finding 1 wearing a different hat —
    /// so `BoilerplateApp` builds the `ModelContainer` and hands the store in,
    /// and a test hands in one backed by `makeInMemoryContainer()`.
    static func live(
        baseURL: URL = AppContainer.defaultBaseURL,
        userStore: any UserPersistenceService,
        syncPolicy: SyncPolicy = .remoteFirst
    ) -> AppContainer {
        let keychain = KeychainWrapper()
        let tokenStore = TokenStore(keychain: keychain)
        let apiClient = URLSessionAPIClient(baseURL: baseURL, tokenStore: tokenStore)

        // One bus, bound to both halves below. Two `EventBus()` expressions
        // would compile, wire cleanly, and deliver nothing — publishers would
        // announce into one and subscribers would wait on the other.
        let eventBus = EventBus()

        // Phase 8 item 4. Read inside out: the live repository talks to the
        // API, the retry loop bounds and repeats what it does, the cache
        // collapses repeated and concurrent reads of the result, and the
        // telemetry measures what a caller waited for — retries and cache hits
        // included, because that is the number a person describing a slow
        // screen is describing. `docs/decorators.md` argues each of those
        // positions, including the two that would be reasonable the other way
        // round.
        let userRepository = TelemetryUserRepository(
            base: CachingUserRepository(
                base: RetryingUserRepository(
                    base: LiveUserRepository(client: apiClient)
                )
            ),
            telemetry: OSLogRepositoryTelemetry(subsystem: AppContainer.logSubsystem)
        )
        let syncStrategyFactory = LiveSyncStrategyFactory(
            repository: userRepository,
            store: userStore
        )

        return AppContainer(
            apiClient: apiClient,
            tokenStore: tokenStore,
            keychain: keychain,
            eventPublisher: eventBus,
            eventSubscriber: eventBus,
            userRepository: userRepository,
            userStore: userStore,
            syncStrategyFactory: syncStrategyFactory,
            syncStrategy: syncStrategyFactory.makeStrategy(for: syncPolicy),
            authService: LiveAuthService(client: apiClient, tokenStore: tokenStore),
            socialAuthProvider: GoogleSignInService(),
            socialAuthExchange: LiveSocialAuthExchangeService(
                client: apiClient,
                tokenStore: tokenStore
            ),
            biometricAuth: LiveBiometricAuthService(),
            textRecognizer: LiveTextRecognitionService(),
            barcodeScanner: LiveBarcodeScannerService(),
            makeCameraService: { CameraService() }
        )
    }
}

// MARK: - The preview graph

@MainActor
extension AppContainer {

    /// The same graph with every collaborator replaced by its hand-written
    /// double — which is the substitution the whole audited surface exists to
    /// make possible, performed once instead of ten times.
    ///
    /// A computed property rather than a stored one: the doubles are mutable
    /// and a preview that stubs a response should not be stubbing it for every
    /// other preview in the process.
    ///
    /// `makeCameraService` still vends a real `CameraService`. There is no
    /// double to vend — see the note on the property — but construction alone
    /// touches no hardware: `CameraService.init` allocates a session and a
    /// preview layer, and nothing is configured or started until `start()`.
    ///
    /// It is `@MainActor` because `MockUserRepository` is: it counts calls from
    /// a mutable stored property and takes the main actor to make that
    /// `Sendable`, which is itself `docs/solid.md` finding 5.
    static var preview: AppContainer {
        // The factory vends the same stub the container resolved, so a preview
        // that pulls to refresh sees the profile it was already showing. Two
        // independent doubles here would make the refresh gesture change the
        // data for no reason a reader could find.
        let syncStrategy = MockSyncStrategy()

        // The real bus, not a double, and it is the one row in this list that is
        // not one. There is nothing here to stub: `EventBus` has no I/O, no
        // policy and no failure mode, so a `MockEventBus` would be a second copy
        // of a broadcast a preview wants to actually work. Substituting it would
        // buy a preview that announces sign-ins nothing receives.
        let eventBus = EventBus()

        return AppContainer(
            apiClient: MockAPIClient(),
            tokenStore: InMemoryTokenStore(),
            keychain: InMemoryKeychain(),
            eventPublisher: eventBus,
            eventSubscriber: eventBus,
            userRepository: MockUserRepository(),
            userStore: MockUserPersistenceService(),
            syncStrategyFactory: MockSyncStrategyFactory(stubbedStrategy: syncStrategy),
            syncStrategy: syncStrategy,
            authService: MockAuthService(),
            socialAuthProvider: MockSocialAuthProvider(),
            socialAuthExchange: MockSocialAuthExchangeService(),
            biometricAuth: MockBiometricAuthService(),
            textRecognizer: MockTextRecognitionService(),
            barcodeScanner: MockBarcodeScannerService(),
            makeCameraService: { CameraService() }
        )
    }
}

// MARK: - View-model factories

/// Every view model in the app is built here and nowhere else.
///
/// The factories are what keep the views ignorant of the graph: a view asks for
/// the view model it owns, and never sees the collaborators behind it. They are
/// `@MainActor` because the view models are.
@MainActor
extension AppContainer {

    func makeLoginViewModel() -> LoginViewModel {
        LoginViewModel(authService: authService, events: eventPublisher)
    }

    func makeSocialLoginViewModel() -> SocialLoginViewModel {
        SocialLoginViewModel(
            googleProvider: socialAuthProvider,
            exchangeService: socialAuthExchange,
            events: eventPublisher
        )
    }

    /// The one auth view model that is not given the publisher.
    ///
    /// A successful Face ID evaluation means "this is the device's owner", not
    /// "a session began" — `BiometricAuthButton` is also used on its own to
    /// re-authenticate somebody who is already signed in, where announcing
    /// `UserSignedIn` would be false. What the evaluation *means* is the calling
    /// screen's to say, so `LoginView` publishes it and this stays a view model
    /// that answers a yes/no question. See `docs/events.md`.
    func makeBiometricAuthViewModel() -> BiometricAuthViewModel {
        BiometricAuthViewModel(service: biometricAuth)
    }

    /// The app's one subscriber to the session events.
    ///
    /// Takes `AppState` rather than holding it: the state is SwiftUI's — a
    /// `@State` on `BoilerplateApp`, installed in the environment — and a
    /// composition root that owned a copy would be a second answer to "is
    /// anybody signed in?".
    func makeSessionObserver(appState: AppState) -> SessionObserver {
        SessionObserver(
            appState: appState,
            tokenStore: tokenStore,
            subscriber: eventSubscriber
        )
    }

    /// `HomeViewModel` has no collaborators yet — it fabricates its list with a
    /// `Task.sleep`, which is `docs/solid.md` finding 6. It is built here
    /// anyway, so that giving it a repository is a change to this method rather
    /// than a change to `HomeView`.
    func makeHomeViewModel() -> HomeViewModel {
        HomeViewModel()
    }

    /// The Settings account section — a `Store`, not a view model, since Phase
    /// 8 item 6.
    ///
    /// The collaborators go to the effect handler rather than to the thing the
    /// view holds, which is the shape the whole pattern turns on: the store
    /// owns state and the handler owns the graph, and neither can do the
    /// other's job. The handler takes the factory as well as the resolved
    /// strategy, because the refresh gesture asks for a policy of its own — see
    /// `ProfileEffectHandler`.
    func makeProfileStore() -> Store<ProfileFeature> {
        Store(
            initialState: ProfileFeature.State(),
            effects: ProfileEffectHandler(
                strategy: syncStrategy,
                strategyFactory: syncStrategyFactory,
                events: eventPublisher
            )
        )
    }

    func makeTextRecognitionViewModel() -> TextRecognitionViewModel {
        TextRecognitionViewModel(
            cameraService: makeCameraService(),
            recognitionService: textRecognizer
        )
    }

    func makeBarcodeScannerViewModel() -> BarcodeScannerViewModel {
        BarcodeScannerViewModel(
            cameraService: makeCameraService(),
            scannerService: barcodeScanner
        )
    }
}
