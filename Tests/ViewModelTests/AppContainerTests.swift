import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

// MARK: - The composition root

/// What `AppContainer` has to be true for, beyond binding the right types —
/// `SolidContractTests` already pins the binding.
///
/// These are the properties that a pile of default arguments *also* satisfied
/// by accident and that a container has to satisfy on purpose: one token store
/// shared across the auth path, a fresh camera session per screen, a graph that
/// can be replaced wholesale, and view models that reach the collaborator the
/// root chose rather than one they picked themselves.
@Suite("AppContainer — the composition root")
@MainActor
struct AppContainerTests {

    // MARK: - Sharing

    /// The property that used to hold because three initialisers happened to
    /// default to the same `TokenStore.shared`, and now holds because one store
    /// is passed to all three.
    ///
    /// This drives the real chain — `LoginViewModel` → `LiveAuthService` →
    /// `TokenStore` — with only the transport faked, and then reads the token
    /// back through the *container's* store rather than through the local. If
    /// the root ever wired a second store in, the read finds nothing.
    @Test("A login through the container's view model writes to the container's token store")
    func loginWritesToTheContainersTokenStore() async throws {
        let tokenStore = InMemoryTokenStore()
        let client = MockAPIClient()
        client.handler = { _ in
            LoginResponse(
                accessToken: "mock-access-token",
                refreshToken: "mock-refresh-token",
                user: User(email: "wired@example.invalid", name: "Wired")
            )
        }

        let container = makeContainer(apiClient: client, tokenStore: tokenStore)
        let viewModel = container.makeLoginViewModel()
        viewModel.email = "wired@example.invalid"
        viewModel.password = "password123"

        await viewModel.login()

        #expect(viewModel.isAuthenticated)
        #expect(viewModel.errorMessage == nil)
        let stored = try await container.tokenStore.currentToken()
        #expect(stored == "mock-access-token")
    }

    /// The exchange service has to reach the same store as the password path,
    /// or a social sign-in leaves the API client holding nothing.
    @Test("A social exchange through the container writes to the same token store")
    func socialExchangeWritesToTheSameTokenStore() async throws {
        let tokenStore = InMemoryTokenStore()
        let client = MockAPIClient()
        client.handler = { _ in
            LoginResponse(
                accessToken: "mock-social-token",
                refreshToken: "mock-social-refresh",
                user: User(email: "social@example.invalid", name: "Social")
            )
        }

        let container = makeContainer(apiClient: client, tokenStore: tokenStore)
        _ = try await container.socialAuthExchange.exchange(
            .apple(
                identityToken: "mock-identity-token",
                authorizationCode: "mock-authorization-code",
                nonce: "mock-nonce",
                fullName: nil
            )
        )

        let stored = try await container.tokenStore.currentToken()
        #expect(stored == "mock-social-token")
    }

    /// Two properties, one object. `eventPublisher` and `eventSubscriber` are
    /// separate so that a collaborator gets the half it needs and not the other,
    /// which means the graph has to be the thing that keeps them the same bus —
    /// two `EventBus()` expressions in `live()` would compile, wire cleanly, and
    /// deliver nothing.
    @Test("Both halves of the event bus are the same object")
    func bothHalvesOfTheBusAreTheSameObject() throws {
        let store = try makeInMemoryUserStore()
        let container = AppContainer.live(userStore: store)

        let publisher = try #require(container.eventPublisher as? EventBus)
        let subscriber = try #require(container.eventSubscriber as? EventBus)
        #expect(publisher === subscriber)
    }

    /// And the same claim from the outside, through the graph the app runs on: a
    /// sign-in announced by the container's own login view model reaches a
    /// subscriber taken from the container's own subscribing half.
    @Test("A view model's publication reaches a subscriber taken from the container")
    func viewModelPublicationsReachTheContainersSubscribers() async throws {
        let tokenStore = InMemoryTokenStore()
        let client = MockAPIClient()
        client.handler = { _ in
            LoginResponse(
                accessToken: "mock-access-token",
                refreshToken: "mock-refresh-token",
                user: User(email: "wired@example.invalid", name: "Wired")
            )
        }

        let container = makeContainer(apiClient: client, tokenStore: tokenStore)
        let stream = container.eventSubscriber.events(of: UserSignedIn.self)

        let viewModel = container.makeLoginViewModel()
        viewModel.email = "wired@example.invalid"
        viewModel.password = "password123"
        await viewModel.login()

        let bus = try #require(container.eventPublisher as? EventBus)
        bus.finish()

        #expect(await collect(from: stream) == [
            UserSignedIn(method: .password, email: "wired@example.invalid"),
        ])
    }

    // MARK: - Lifetimes

    /// Both camera screens used to default to `CameraService()`, so each got its
    /// own `AVCaptureSession` by accident. The factory states the choice, and
    /// this is what says the choice is still "one per screen": two calls, two
    /// objects. Reversing it — one shared session — should fail here first.
    @Test("The camera factory vends a new service per call")
    func cameraFactoryVendsAFreshServicePerCall() {
        let container = AppContainer.preview
        let first = container.makeCameraService()
        let second = container.makeCameraService()
        #expect(first !== second)
    }

    /// `preview` is a computed property, not a stored one, because the doubles
    /// are mutable: a preview that stubs a response must not be stubbing it for
    /// every other preview in the process.
    @Test("Each access to the preview container builds fresh doubles")
    func previewContainerIsRebuiltPerAccess() throws {
        let first = try #require(AppContainer.preview.apiClient as? MockAPIClient)
        let second = try #require(AppContainer.preview.apiClient as? MockAPIClient)
        #expect(first !== second)
    }

    // MARK: - Configuration

    /// The API origin is a decision of the root's, and threading it is the
    /// whole reason `URLSessionAPIClient.shared` — which hardcoded it — is gone.
    @Test("live(baseURL:) threads the origin into the transport")
    func liveThreadsTheBaseURL() throws {
        let custom = URL(string: "https://api.example.invalid/v2")!
        let store = try makeInMemoryUserStore()

        let client = try #require(
            AppContainer.live(baseURL: custom, userStore: store).apiClient as? URLSessionAPIClient
        )
        #expect(client.baseURL == custom)

        let byDefault = try #require(
            AppContainer.live(userStore: store).apiClient as? URLSessionAPIClient
        )
        #expect(byDefault.baseURL == AppContainer.defaultBaseURL)
    }

    /// The Strategy half of Phase 8 item 3: the policy argument is the only
    /// thing that decides how every profile read in the app behaves, and it is
    /// read back off the object the root resolved rather than off its type name.
    @Test("live(syncPolicy:) resolves the policy it was given", arguments: SyncPolicy.allCases)
    func liveResolvesTheRequestedSyncPolicy(policy: SyncPolicy) throws {
        let store = try makeInMemoryUserStore()
        let container = AppContainer.live(userStore: store, syncPolicy: policy)
        #expect(container.syncStrategy.policy == policy)
    }

    /// `offlineFirst` is the app's default as of Phase 9 item 1: the stored row
    /// answers while it is fresh, and the stamp that decides "fresh" is on the
    /// row, so a launch inside the window costs no request at all.
    ///
    /// It was `remoteFirst`, and that argument — a read that always costs a
    /// request is never quietly stale — did not lose, it moved. It is now the
    /// argument for the *refresh gesture*, which `ProfileFeature` still asks
    /// the factory for by name.
    @Test("The default sync policy is offlineFirst")
    func liveDefaultsToOfflineFirst() throws {
        let store = try makeInMemoryUserStore()
        let container = AppContainer.live(userStore: store)
        #expect(container.syncStrategy.policy == .offlineFirst)
    }

    /// The Factory half. A view model that needs a policy of its own asks the
    /// root's factory rather than naming a strategy type, and the factory it
    /// gets is bound to the same graph.
    @Test("The container's factory builds strategies over the container's collaborators")
    func factoryBuildsOverTheContainersGraph() throws {
        let container = AppContainer.preview
        let vended = try #require(
            container.syncStrategyFactory.makeStrategy(for: .cacheFirst) as? MockSyncStrategy
        )
        let resolved = try #require(container.syncStrategy as? MockSyncStrategy)
        #expect(vended === resolved)
    }

    // MARK: - View-model factories

    /// A view model built by the container reaches the collaborator the root
    /// chose. `MockAuthService` fails on demand, and the failure has to surface
    /// through the view model that the container handed back.
    @Test("makeLoginViewModel injects the container's auth service")
    func loginViewModelUsesTheContainersAuthService() async throws {
        let container = AppContainer.preview
        let service = try #require(container.authService as? MockAuthService)
        service.shouldSucceed = false
        service.delay = .zero

        let viewModel = container.makeLoginViewModel()
        viewModel.email = "user@example.invalid"
        viewModel.password = "password123"
        await viewModel.login()

        #expect(!viewModel.isAuthenticated)
        #expect(viewModel.errorMessage != nil)
    }

    /// The same claim for the biometric screen, read through a property rather
    /// than an action: `isAvailable` is forwarded straight from the provider.
    @Test("makeBiometricAuthViewModel injects the container's provider")
    func biometricViewModelUsesTheContainersProvider() throws {
        let container = AppContainer.preview
        let provider = try #require(container.biometricAuth as? MockBiometricAuthService)
        provider.stubbedIsAvailable = false
        provider.stubbedBiometricType = .none

        let viewModel = container.makeBiometricAuthViewModel()
        #expect(!viewModel.isAvailable)
        #expect(viewModel.biometricType == .none)
    }

    /// The camera view models are the two the audit's construction pin could
    /// never cover, because building one used to build a `CameraService` behind
    /// your back. Now the service arrives from the factory, so asserting the
    /// view model got *that* one is possible: both read `previewLayer` off the
    /// service they were handed.
    @Test("The camera view models are built on the service the factory vended")
    func cameraViewModelsUseTheFactoriesService() {
        let container = AppContainer.preview
        let recognition = container.makeTextRecognitionViewModel()
        let scanner = container.makeBarcodeScannerViewModel()
        #expect(recognition.previewLayer !== scanner.previewLayer)
    }

    // MARK: - Helpers

    /// A container whose transport and token store are the caller's and whose
    /// auth services are the real ones, so a test can drive the live auth path
    /// with nothing but the network faked.
    private func makeContainer(
        apiClient: any APIClient,
        tokenStore: any TokenStoring
    ) -> AppContainer {
        let userRepository = LiveUserRepository(client: apiClient)
        let userStore = MockUserPersistenceService()
        let syncStrategyFactory = LiveSyncStrategyFactory(
            repository: userRepository,
            store: userStore
        )

        let eventBus = EventBus()

        return AppContainer(
            apiClient: apiClient,
            tokenStore: tokenStore,
            keychain: InMemoryKeychain(),
            eventPublisher: eventBus,
            eventSubscriber: eventBus,
            userRepository: userRepository,
            userStore: userStore,
            syncStrategyFactory: syncStrategyFactory,
            syncStrategy: syncStrategyFactory.makeStrategy(for: .remoteFirst),
            authService: LiveAuthService(client: apiClient, tokenStore: tokenStore),
            socialAuthProvider: MockSocialAuthProvider(),
            socialAuthExchange: LiveSocialAuthExchangeService(
                client: apiClient,
                tokenStore: tokenStore
            ),
            biometricAuth: MockBiometricAuthService(),
            textRecognizer: MockTextRecognitionService(),
            barcodeScanner: MockBarcodeScannerService(),
            backgroundRefresh: BackgroundRefreshCoordinator(
                policy: BackgroundRefreshPolicy(identifier: AppContainer.backgroundRefreshIdentifier),
                scheduler: MockBackgroundTaskScheduler(),
                ledger: InMemoryBackgroundRefreshLedger(),
                subsystem: AppContainer.logSubsystem,
                refresh: {}
            ),
            makeCameraService: { CameraService() }
        )
    }

    /// A live graph needs a real `UserPersistenceService`, and building one
    /// needs a `ModelContext`. In-memory rather than disk-backed so the suite
    /// leaves nothing behind; `PersistenceController` already vends both.
    private func makeInMemoryUserStore() throws -> any UserPersistenceService {
        let modelContainer = try PersistenceController.makeInMemoryContainer()
        return SwiftDataUserPersistenceService(context: modelContainer.mainContext)
    }
}

// MARK: - The TokenStoring seam

/// `docs/solid.md` finding 2: `TokenStore` was depended on as a concrete actor,
/// so a test that needed "a store with no valid token" had to build a fake
/// Keychain and leave it empty. These are the tests that the protocol makes
/// writable — each one substitutes the store itself.
@Suite("TokenStoring — the seam finding 2 asked for")
struct TokenStoringSeamTests {

    /// The transport asks its store for a token before it builds a request, so
    /// an empty store fails an authenticated endpoint without reaching the
    /// network at all — `URLSession.shared` is the default here and is never
    /// touched, which is also why this test is fast rather than a real request
    /// to a placeholder host.
    ///
    /// And it must fail rather than try to refresh: a refresh needs a refresh
    /// token, and an empty store has none either. Observing that from the
    /// outside is what the protocol bought — `refreshCount` is a property of
    /// the substituted store, not of the transport.
    @Test("A missing token throws at the store rather than triggering a refresh")
    func missingTokenDoesNotTriggerARefresh() async {
        let store = InMemoryTokenStore()
        let client = URLSessionAPIClient(
            baseURL: AppContainer.defaultBaseURL,
            tokenStore: store
        )

        await #expect(throws: APIError.self) {
            let _: User = try await client.send(APIEndpoint.get("/users/me"))
        }

        let refreshes = await store.refreshCount
        #expect(refreshes == 0)
    }

    @Test("The double stores, returns and clears a pair")
    func doubleStoresAndClears() async throws {
        let store = InMemoryTokenStore()
        // No `try`: the protocol requirement is `async throws`, but this
        // conformer's `setTokens` is neither — a non-throwing method witnesses a
        // throwing requirement, and calling the *concrete* type gets the
        // concrete signature. `currentToken()` below does throw, on both.
        await store.setTokens(
            TokenPair(accessToken: "mock-access-token", refreshToken: "mock-refresh-token")
        )
        let token = try await store.currentToken()
        #expect(token == "mock-access-token")

        await store.clearTokens()
        await #expect(throws: APIError.self) {
            _ = try await store.currentToken()
        }
    }

    /// The double's performer runs once per call and hands the refresh token it
    /// was holding, which is what a decorator testing a retry policy (Phase 8
    /// item 4) will need to assert against.
    @Test("The double runs its performer and adopts the new pair")
    func doubleRefreshesThroughItsPerformer() async throws {
        let store = InMemoryTokenStore(
            pair: TokenPair(accessToken: "mock-stale-token", refreshToken: "mock-refresh-token")
        )

        let fresh = try await store.refreshIfNeeded { refreshToken in
            #expect(refreshToken == "mock-refresh-token")
            return TokenPair(
                accessToken: "mock-fresh-token",
                refreshToken: "mock-refresh-token-2"
            )
        }

        #expect(fresh == "mock-fresh-token")
        let current = try await store.currentToken()
        #expect(current == "mock-fresh-token")
        let count = await store.refreshCount
        #expect(count == 1)
    }

    /// A store with nothing to refresh from throws rather than calling the
    /// performer, matching `TokenStore`'s own precondition.
    @Test("The double refuses to refresh with no stored refresh token")
    func doubleRefusesToRefreshWhenEmpty() async {
        let store = InMemoryTokenStore()

        await #expect(throws: APIError.self) {
            _ = try await store.refreshIfNeeded { _ in
                Issue.record("The performer must not run without a refresh token.")
                return TokenPair(accessToken: "unused", refreshToken: "unused")
            }
        }
    }
}
