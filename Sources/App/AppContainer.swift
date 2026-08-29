import Core
import Features
import Foundation
import Networking

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

    /// Keeps the profile refreshed while the app is not running.
    ///
    /// Held by the root rather than built inside the `.backgroundTask` closure
    /// for the reason the whole type exists: the closure runs in a process that
    /// may have been launched for nothing else, so a coordinator constructed
    /// there would be constructing the graph it needs from inside the handler —
    /// finding 1 again, in the one place where getting it wrong is invisible
    /// because nobody is watching the screen.
    let backgroundRefresh: BackgroundRefreshCoordinator

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

    /// The identifier the profile refresh is registered and launched under.
    ///
    /// It is stated once, here, because it has to be the same string in three
    /// places that cannot check each other: this container's
    /// `BackgroundRefreshPolicy`, the `.backgroundTask(.appRefresh(_:))`
    /// modifier in `BoilerplateApp`, and the app's
    /// `BGTaskSchedulerPermittedIdentifiers` array. The first two are now one
    /// constant. The third is an Info.plist entry no Swift declaration can
    /// reach — and a mismatch there is not a returned error but a raised
    /// exception on the first submit, so `docs/background-refresh.md` spells
    /// the plist out rather than leaving it to be discovered.
    static let backgroundRefreshIdentifier = "com.example.boilerplate-ios-swift.refresh-profile"
}

// MARK: - Why a cached answer is a failed background refresh

/// What the background refresh throws when it ran but did not reach the API.
///
/// It exists because `RemoteFirstSyncStrategy` is deliberately forgiving: asked
/// for the profile with the radio down, it answers out of the store and reports
/// `SyncOrigin.localCache` rather than throwing, which is exactly right for a
/// screen and exactly wrong for a ledger. A background launch that read its own
/// cache has refreshed nothing; counting it as a success would clear the
/// failure count, collapse the backoff, and leave a device that has been
/// offline for a day waking up every fifteen minutes to re-read its own disk.
///
/// So the closure in `live()` inspects the origin and throws this. The
/// alternative — asking for `.remoteOnly`, which never falls back — was
/// rejected because it also never writes through, so a successful background
/// fetch would leave the store exactly as stale as it found it.
enum BackgroundRefreshFailure: LocalizedError, Equatable {
    /// The read was answered from the local store, so nothing was refreshed.
    case answeredFromCache

    var errorDescription: String? {
        switch self {
        case .answeredFromCache:
            "The background refresh was answered from the local store, so nothing was fetched."
        }
    }
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
    ///
    /// The default policy is `offlineFirst` as of Phase 9 item 1.
    ///
    /// It was `remoteFirst`, chosen as the conservative default on the grounds
    /// that a read which always costs a request is never quietly stale. That
    /// argument survives, and it is now the argument for the *refresh gesture*
    /// rather than for the app's standing policy: `ProfileFeature` still asks
    /// the factory for `remoteFirst` when the reader pulls to refresh, which is
    /// the whole reason the factory is a seam.
    ///
    /// What changed is what a launch costs. Under `remoteFirst` every profile
    /// read on a device with no connection is a failure the store then papers
    /// over; under `offlineFirst` it is an answer, and the request only happens
    /// when the stored row has actually aged past the window. A boilerplate
    /// whose Phase 9 is titled "Offline-First" should ship with the app wired
    /// that way rather than with the policy present and unreachable.
    static func live(
        baseURL: URL = AppContainer.defaultBaseURL,
        userStore: any UserPersistenceService,
        syncPolicy: SyncPolicy = .offlineFirst
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

        // Phase 9 item 2. The background leg asks the factory for
        // `.remoteFirst` instead of reusing the strategy resolved below, for
        // the same reason `ProfileFeature`'s pull-to-refresh does: under
        // `offlineFirst` a read inside the freshness window is answered off the
        // row and costs no request, which is the correct behaviour for a screen
        // and a wasted process launch for a background task whose entire job is
        // to make that row fresher.
        let backgroundStrategy = syncStrategyFactory.makeStrategy(for: .remoteFirst)
        let backgroundRefresh = BackgroundRefreshCoordinator(
            policy: BackgroundRefreshPolicy(identifier: AppContainer.backgroundRefreshIdentifier),
            scheduler: SystemBackgroundTaskScheduler(),
            ledger: UserDefaultsBackgroundRefreshLedger(
                taskIdentifier: AppContainer.backgroundRefreshIdentifier
            ),
            subsystem: AppContainer.logSubsystem,
            refresh: {
                let synced = try await backgroundStrategy.loadCurrentUser()
                guard synced.origin == .remote else {
                    throw BackgroundRefreshFailure.answeredFromCache
                }
            }
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
            backgroundRefresh: backgroundRefresh,
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

        // A coordinator whose scheduler records rather than submits. Building a
        // real one here would be the one line in this list that reaches out of
        // the process: `BGTaskScheduler.submit` raises for an identifier that
        // is not in the host's `BGTaskSchedulerPermittedIdentifiers`, and a
        // preview host has no such array — so the double is what keeps
        // `AppContainer.preview` constructible from a preview and a test at all.
        let backgroundRefresh = BackgroundRefreshCoordinator(
            policy: BackgroundRefreshPolicy(identifier: AppContainer.backgroundRefreshIdentifier),
            scheduler: MockBackgroundTaskScheduler(),
            ledger: InMemoryBackgroundRefreshLedger(),
            subsystem: AppContainer.logSubsystem,
            refresh: { _ = try await syncStrategy.loadCurrentUser() }
        )

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
            backgroundRefresh: backgroundRefresh,
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

// MARK: - What each screen is allowed to ask for

/// The container's side of the five per-screen protocols in `Features`.
///
/// Every requirement is already satisfied by the factories above — this adds no
/// code, only the statement that the root can be handed to a screen. The
/// direction is what matters: before the package was split into targets a view
/// named `AppContainer`, so a change to any screen's collaborators was a change
/// every other screen could see. Now the screen names what it needs and the root
/// answers, which is the edge that lets `Features` compile without this file.
///
/// `AppContainer` stays `internal`. Nothing depends on this target, and a
/// composition root that advertised itself would be inviting exactly the
/// dependency the protocols exist to remove.
extension AppContainer: LoginDependencies, HomeDependencies, SettingsDependencies {}

extension AppContainer: TextRecognitionDependencies, BarcodeScannerDependencies {}
