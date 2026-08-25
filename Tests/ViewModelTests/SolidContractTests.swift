import Foundation
import SwiftData
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

// MARK: - The audit primitive

/// Records `type` in the audit.
///
/// The names exist so a dropped entry shows up as a count mismatch rather than
/// as a silently shorter list, in the same shape `SendableConformanceTests`
/// already uses. The *conformance* half of each claim is not recorded here — it
/// is carried by the `let x: any Abstraction = Concrete()` bindings below, which
/// stop compiling when a conformance goes away.
private func audit<T>(_ type: T.Type) -> String {
    String(describing: type)
}

/// Every audited name must be distinct, so a copy-paste that repeats a line
/// cannot pad the count in place of an entry that was dropped.
private func expectAudit(_ audited: [String], count: Int) {
    #expect(audited.count == count)
    #expect(Set(audited).count == audited.count)
}

/// Finding 5, compile-time half: this function is `nonisolated`, so it can only
/// build a repository that is not actor-isolated.
///
/// `LiveUserRepository` is a plain `struct` and `MockUserRepository` is a
/// `@MainActor final class`, so substituting the double changes where the work
/// runs. The tempting repair is to annotate the live type with `@MainActor` so
/// the two agree; `docs/solid.md` argues for the other direction — put the
/// double's call counts inside a lock, as `MockAPIClient` and `MockAuthService`
/// already do. Either way this function is where the first attempt lands: adding
/// a global actor to `LiveUserRepository` breaks the build here instead of
/// leaving the page describing an isolation split that is gone.
private func makeLiveRepositoryOffTheMainActor() -> any UserRepository {
    LiveUserRepository(
        client: URLSessionAPIClient(
            baseURL: AppContainer.defaultBaseURL,
            tokenStore: InMemoryTokenStore()
        )
    )
}

/// Finding 8, compile-time half: conforming to `ViewModelProtocol` demands
/// nothing, because both of its requirements carry default implementations.
///
/// An empty body is a complete conformance. Giving the protocol a requirement
/// that a conformer has to answer — which is what Phase 8 item 6 will do when it
/// replaces this with a `State`/`Action`/`Effect` contract — stops this type
/// compiling.
private final class EmptyViewModelConformer: ViewModelProtocol {}

// MARK: - The audited surface

/// The table at the top of `docs/solid.md`, as code.
@Suite("SOLID contract — the audited surface")
@MainActor
struct SolidSurfaceTests {

    /// Each binding below is the pin: the annotation names the abstraction, the
    /// initialiser names the live implementation, and the coercion between them
    /// is checked by the compiler. A conformance removed from any of these types
    /// is a build failure in this file, pointing at the row of the table that
    /// stopped being true.
    ///
    /// `AppleSignInService` is in the list even though nothing constructs it in
    /// production — that *is* finding 8, and keeping it here means deleting the
    /// type (the repair the finding recommends) fails the build rather than
    /// leaving the page describing dead code that is gone.
    ///
    /// `SwiftDataUserPersistenceService` is the one row of the table missing
    /// here: it needs a `ModelContext` to exist at all, so it is pinned in
    /// `SolidSubstitutabilityTests`, which is the suite that builds a container.
    /// The strategies below take a store, so they are handed the double for the
    /// same reason — what is pinned here is their conformance, not their wiring.
    @Test("Every abstraction in docs/solid.md still has its live implementation")
    func liveImplementationsStillConform() {
        let keychain: any KeychainStoring = KeychainWrapper()
        let tokenStore: any TokenStoring = TokenStore(keychain: keychain)
        let client: any APIClient = URLSessionAPIClient(
            baseURL: AppContainer.defaultBaseURL,
            tokenStore: tokenStore
        )
        let repository: any UserRepository = LiveUserRepository(client: client)
        let auth: any AuthServiceProtocol = LiveAuthService(client: client, tokenStore: tokenStore)
        let exchange: any SocialAuthExchangeService = LiveSocialAuthExchangeService(
            client: client,
            tokenStore: tokenStore
        )
        let apple: any SocialAuthProvider = AppleSignInService()
        let google: any SocialAuthProvider = GoogleSignInService()
        let biometrics: any BiometricAuthProvider = LiveBiometricAuthService()
        let recognizer: any TextRecognizing = LiveTextRecognitionService()
        let scanner: any BarcodeScanning = LiveBarcodeScannerService()
        let store: any UserPersistenceService = MockUserPersistenceService()
        let syncFactory: any SyncStrategyFactory = LiveSyncStrategyFactory(
            repository: repository,
            store: store
        )
        let remoteOnly: any SyncStrategy = RemoteOnlySyncStrategy(repository: repository)
        let remoteFirst: any SyncStrategy = RemoteFirstSyncStrategy(
            repository: repository,
            store: store
        )
        let cacheFirst: any SyncStrategy = CacheFirstSyncStrategy(
            repository: repository,
            store: store,
            maxAge: .seconds(60)
        )

        let bound: [Any] = [
            client, tokenStore, repository, auth, exchange, apple,
            google, biometrics, recognizer, scanner, keychain,
            syncFactory, remoteOnly, remoteFirst, cacheFirst,
        ]

        let audited = [
            audit(URLSessionAPIClient.self),
            audit(TokenStore.self),
            audit(LiveUserRepository.self),
            audit(LiveAuthService.self),
            audit(LiveSocialAuthExchangeService.self),
            audit(AppleSignInService.self),
            audit(GoogleSignInService.self),
            audit(LiveBiometricAuthService.self),
            audit(LiveTextRecognitionService.self),
            audit(LiveBarcodeScannerService.self),
            audit(KeychainWrapper.self),
            audit(LiveSyncStrategyFactory.self),
            audit(RemoteOnlySyncStrategy.self),
            audit(RemoteFirstSyncStrategy.self),
            audit(CacheFirstSyncStrategy.self),
        ]

        expectAudit(audited, count: 15)
        #expect(bound.count == audited.count)
    }

    /// The doubles, audited for the same reason and separately, because the
    /// point of findings 3 to 5 is that these are independent reimplementations
    /// rather than generated stand-ins.
    @Test("Every abstraction still has its hand-written double")
    func doublesStillConform() {
        let client: any APIClient = MockAPIClient()
        let tokenStore: any TokenStoring = InMemoryTokenStore()
        let keychain: any KeychainStoring = InMemoryKeychain()
        let repository: any UserRepository = MockUserRepository()
        let persistence: any UserPersistenceService = MockUserPersistenceService()
        let auth: any AuthServiceProtocol = MockAuthService()
        let provider: any SocialAuthProvider = MockSocialAuthProvider()
        let exchange: any SocialAuthExchangeService = MockSocialAuthExchangeService()
        let biometrics: any BiometricAuthProvider = MockBiometricAuthService()
        let recognizer: any TextRecognizing = MockTextRecognitionService()
        let scanner: any BarcodeScanning = MockBarcodeScannerService()
        let syncStrategy: any SyncStrategy = MockSyncStrategy()
        let syncFactory: any SyncStrategyFactory = MockSyncStrategyFactory()

        let bound: [Any] = [
            client, tokenStore, keychain, repository, persistence, auth, provider,
            exchange, biometrics, recognizer, scanner, syncStrategy, syncFactory,
        ]

        let audited = [
            audit(MockAPIClient.self),
            audit(InMemoryTokenStore.self),
            audit(InMemoryKeychain.self),
            audit(MockUserRepository.self),
            audit(MockUserPersistenceService.self),
            audit(MockAuthService.self),
            audit(MockSocialAuthProvider.self),
            audit(MockSocialAuthExchangeService.self),
            audit(MockBiometricAuthService.self),
            audit(MockTextRecognitionService.self),
            audit(MockBarcodeScannerService.self),
            audit(MockSyncStrategy.self),
            audit(MockSyncStrategyFactory.self),
        ]

        expectAudit(audited, count: 13)
        #expect(bound.count == audited.count)
    }

    /// Finding 1, as repaired: the composition root is `AppContainer`, and it
    /// is the only place in the package that names a live implementation.
    ///
    /// This replaces `zeroArgumentConstructionStillCompiles`, which constructed
    /// `LoginViewModel()`, `SocialLoginViewModel()`, `BiometricAuthViewModel()`,
    /// `LiveAuthService()`, `LiveUserRepository()` and
    /// `LiveSocialAuthExchangeService()` with no arguments at all, and which the
    /// audit predicted would stop compiling the moment a container took those
    /// defaults off. It did, and it was rewritten rather than relaxed: none of
    /// those six initialisers has a default argument any more, so none of those
    /// six expressions is spellable.
    ///
    /// What is pinned instead is the wiring. Asserting on the *dynamic* type of
    /// each existential is what makes this a check rather than a restatement:
    /// swapping `live()`'s `GoogleSignInService` for a double, or letting a
    /// default creep back in under one of these properties, changes a name here.
    ///
    /// `AppleSignInService` has no row — it is constructed by nothing, in the
    /// container or out of it, which is finding 8 and is pinned by
    /// `liveImplementationsStillConform` above.
    ///
    /// The `userRepository` row names `TelemetryUserRepository` as of Phase 8
    /// item 4: the container binds a decorator chain rather than a bare
    /// `LiveUserRepository`, and this row sees its outermost link. What is
    /// *inside* it is a separate claim with its own pin —
    /// `decoratorChainIsTelemetryOverCacheOverRetry` walks all four names in
    /// order — because a row here would go green on any composition that
    /// happened to end up with the same wrapper on the outside.
    @Test("The container is the composition root, and it binds the live graph")
    func liveContainerBindsTheLiveGraph() throws {
        let modelContainer = try PersistenceController.makeInMemoryContainer()
        let container = AppContainer.live(
            userStore: SwiftDataUserPersistenceService(context: modelContainer.mainContext)
        )

        let bound = [
            String(describing: type(of: container.apiClient)),
            String(describing: type(of: container.tokenStore)),
            String(describing: type(of: container.keychain)),
            String(describing: type(of: container.eventPublisher)),
            String(describing: type(of: container.eventSubscriber)),
            String(describing: type(of: container.userRepository)),
            String(describing: type(of: container.userStore)),
            String(describing: type(of: container.syncStrategyFactory)),
            String(describing: type(of: container.syncStrategy)),
            String(describing: type(of: container.authService)),
            String(describing: type(of: container.socialAuthProvider)),
            String(describing: type(of: container.socialAuthExchange)),
            String(describing: type(of: container.biometricAuth)),
            String(describing: type(of: container.textRecognizer)),
            String(describing: type(of: container.barcodeScanner)),
        ]

        #expect(bound == [
            "URLSessionAPIClient",
            "TokenStore",
            "KeychainWrapper",
            "EventBus",
            "EventBus",
            "TelemetryUserRepository",
            "SwiftDataUserPersistenceService",
            "LiveSyncStrategyFactory",
            "RemoteFirstSyncStrategy",
            "LiveAuthService",
            "GoogleSignInService",
            "LiveSocialAuthExchangeService",
            "LiveBiometricAuthService",
            "LiveTextRecognitionService",
            "LiveBarcodeScannerService",
        ])
    }

    /// The other half of finding 1: substituting the whole graph is now one
    /// expression, where it used to be ten arguments spread over six call sites.
    @Test("The preview container binds the doubles instead")
    func previewContainerBindsTheDoubles() {
        let container = AppContainer.preview

        let bound = [
            String(describing: type(of: container.apiClient)),
            String(describing: type(of: container.tokenStore)),
            String(describing: type(of: container.keychain)),
            String(describing: type(of: container.userRepository)),
            String(describing: type(of: container.userStore)),
            String(describing: type(of: container.syncStrategyFactory)),
            String(describing: type(of: container.syncStrategy)),
            String(describing: type(of: container.authService)),
            String(describing: type(of: container.socialAuthProvider)),
            String(describing: type(of: container.socialAuthExchange)),
            String(describing: type(of: container.biometricAuth)),
            String(describing: type(of: container.textRecognizer)),
            String(describing: type(of: container.barcodeScanner)),
        ]

        #expect(bound.allSatisfy { $0.hasPrefix("Mock") || $0.hasPrefix("InMemory") })
        #expect(bound.count == 13)

        // `eventPublisher` and `eventSubscriber` are deliberately absent from
        // that list, because they are the one pair the preview graph does not
        // substitute — see `AppContainer.preview`. Asserted here rather than
        // omitted, so that the exception is a stated one: a double appearing
        // under either name later should have to change this line.
        #expect(String(describing: type(of: container.eventPublisher)) == "EventBus")
        #expect(String(describing: type(of: container.eventSubscriber)) == "EventBus")
    }

    /// Finding 8: the conformance costs nothing to satisfy.
    ///
    /// The runtime half is thin on purpose — what matters is that
    /// `EmptyViewModelConformer` compiles at all. Calling both members proves
    /// the defaults are what answered for it.
    @Test("An empty type satisfies ViewModelProtocol")
    func emptyConformanceSatisfiesViewModelProtocol() async {
        let conformer: any ViewModelProtocol = EmptyViewModelConformer()
        await conformer.onAppear()
        conformer.onDisappear()
        #expect(String(describing: type(of: conformer)) == "EmptyViewModelConformer")
    }
}

// MARK: - Substitutability

/// The differential half of the audit: a live implementation and its double run
/// through the same script, asserting that they **disagree**.
///
/// Reading these as ordinary tests gets them backwards. Each one fails when the
/// divergence it describes is repaired, which is exactly what should happen —
/// the repair and the edit to `docs/solid.md` then land together, instead of the
/// page outliving the problem it documents.
///
/// `.serialized` and the stored container follow `UserPersistenceTests`: a
/// `ModelContext` does not keep its `ModelContainer` alive, and a container
/// built inside a helper is deallocated before the test body runs, which
/// SwiftData reports by trapping and taking the whole test process with it.
@Suite("SOLID contract — substitutability", .serialized)
@MainActor
struct SolidSubstitutabilityTests {

    private let container: ModelContainer
    private let store: SwiftDataUserPersistenceService

    init() throws {
        container = try PersistenceController.makeInMemoryContainer()
        store = SwiftDataUserPersistenceService(context: container.mainContext)
    }

    /// The row of the audited surface that `SolidSurfaceTests` cannot reach,
    /// because the store does not exist without a `ModelContext`. Same pin as
    /// every other row: the coercion to the existential is what the compiler
    /// checks, and the assertion is only there to use the result.
    @Test("The SwiftData store still satisfies UserPersistenceService")
    func swiftDataStoreStillConforms() {
        let persistence: any UserPersistenceService = store
        let name = String(describing: type(of: persistence))
        #expect(name == "SwiftDataUserPersistenceService")
    }

    /// Finding 3: `save(user:)` inserts in the store and upserts in the double.
    ///
    /// `UserEntity.id` carries no `@Attribute(.unique)` — see the comment on the
    /// model for why that is the right call — so nothing collapses the second
    /// row. The double keys a dictionary on `user.id`, so nothing preserves it.
    /// Two rows against one entry is the whole finding.
    @Test("save() is an insert in the store and an upsert in its double")
    func saveDivergesBetweenImplementations() throws {
        let user = User(email: "duplicate@example.invalid", name: "Duplicate")

        try store.save(user: user)
        try store.save(user: user)
        let rows = try container.mainContext.fetch(FetchDescriptor<UserEntity>())

        let double = MockUserPersistenceService()
        try double.save(user: user)
        try double.save(user: user)

        #expect(rows.count == 2)
        #expect(double.storage.count == 1)
    }

    /// Finding 4: the two `UserRepository` implementations throw types that do
    /// not overlap.
    ///
    /// `LiveUserRepository` forwards to `APIClient`, so `APIError` is what comes
    /// out of it; `UserRepositoryError` — the enum with the user-facing
    /// descriptions — is thrown by the double and by nothing else in the
    /// package. A caller that catches one handles none of the other's failures.
    @Test("The repository's two implementations throw disjoint error types")
    func repositoryErrorTypesAreDisjoint() async {
        let client = MockAPIClient()
        client.handler = { _ in throw APIError.unauthorized }
        let live = LiveUserRepository(client: client)

        await #expect(throws: APIError.self) {
            _ = try await live.fetchCurrentUser()
        }

        let double = MockUserRepository()
        double.shouldThrow = true

        await #expect(throws: UserRepositoryError.self) {
            _ = try await double.fetchCurrentUser()
        }
    }

    /// Finding 5, runtime half. The compile-time half is
    /// `makeLiveRepositoryOffTheMainActor()`; this is what uses it, so the
    /// function cannot be dropped as unreferenced while the finding stands.
    @Test("The live repository is constructible outside the main actor")
    func liveRepositoryIsNotActorIsolated() {
        let repository = makeLiveRepositoryOffTheMainActor()
        #expect(String(describing: type(of: repository)) == "LiveUserRepository")
    }
}
