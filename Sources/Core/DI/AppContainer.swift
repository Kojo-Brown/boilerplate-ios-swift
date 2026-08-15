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
/// `UserPersistenceService` is not here. It needs a `ModelContext`, which is
/// not `Sendable`, and `docs/solid.md` finding 6 records that neither it nor
/// `UserRepository` is on any data path today. Wiring a store that has no
/// caller would be inventing a caller; that is Phase 9 item 1's job, and it is
/// the item that will decide what isolation the store lives under.
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

    /// User-profile data operations.
    let userRepository: any UserRepository

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
    static func live(baseURL: URL = AppContainer.defaultBaseURL) -> AppContainer {
        let keychain = KeychainWrapper()
        let tokenStore = TokenStore(keychain: keychain)
        let apiClient = URLSessionAPIClient(baseURL: baseURL, tokenStore: tokenStore)

        return AppContainer(
            apiClient: apiClient,
            tokenStore: tokenStore,
            keychain: keychain,
            userRepository: LiveUserRepository(client: apiClient),
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
        AppContainer(
            apiClient: MockAPIClient(),
            tokenStore: InMemoryTokenStore(),
            keychain: InMemoryKeychain(),
            userRepository: MockUserRepository(),
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
        LoginViewModel(authService: authService)
    }

    func makeSocialLoginViewModel() -> SocialLoginViewModel {
        SocialLoginViewModel(
            googleProvider: socialAuthProvider,
            exchangeService: socialAuthExchange
        )
    }

    func makeBiometricAuthViewModel() -> BiometricAuthViewModel {
        BiometricAuthViewModel(service: biometricAuth)
    }

    /// `HomeViewModel` has no collaborators yet — it fabricates its list with a
    /// `Task.sleep`, which is `docs/solid.md` finding 6. It is built here
    /// anyway, so that giving it a repository is a change to this method rather
    /// than a change to `HomeView`.
    func makeHomeViewModel() -> HomeViewModel {
        HomeViewModel()
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
