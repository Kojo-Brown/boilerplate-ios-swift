import Foundation
import SwiftData
import Testing
@testable import BoilerplateiOSSwift

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
    LiveUserRepository(client: URLSessionAPIClient.shared)
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
    @Test("Every abstraction in docs/solid.md still has its live implementation")
    func liveImplementationsStillConform() {
        let client: any APIClient = URLSessionAPIClient.shared
        let repository: any UserRepository = LiveUserRepository(client: client)
        let auth: any AuthServiceProtocol = LiveAuthService(client: client)
        let exchange: any SocialAuthExchangeService = LiveSocialAuthExchangeService(client: client)
        let apple: any SocialAuthProvider = AppleSignInService()
        let google: any SocialAuthProvider = GoogleSignInService()
        let biometrics: any BiometricAuthProvider = LiveBiometricAuthService()
        let recognizer: any TextRecognizing = LiveTextRecognitionService()
        let scanner: any BarcodeScanning = LiveBarcodeScannerService()
        let keychain: any KeychainStoring = KeychainWrapper()

        let bound: [Any] = [
            client, repository, auth, exchange, apple,
            google, biometrics, recognizer, scanner, keychain,
        ]

        let audited = [
            audit(URLSessionAPIClient.self),
            audit(LiveUserRepository.self),
            audit(LiveAuthService.self),
            audit(LiveSocialAuthExchangeService.self),
            audit(AppleSignInService.self),
            audit(GoogleSignInService.self),
            audit(LiveBiometricAuthService.self),
            audit(LiveTextRecognitionService.self),
            audit(LiveBarcodeScannerService.self),
            audit(KeychainWrapper.self),
        ]

        expectAudit(audited, count: 10)
        #expect(bound.count == audited.count)
    }

    /// The doubles, audited for the same reason and separately, because the
    /// point of findings 3 to 5 is that these are independent reimplementations
    /// rather than generated stand-ins.
    @Test("Every abstraction still has its hand-written double")
    func doublesStillConform() {
        let client: any APIClient = MockAPIClient()
        let repository: any UserRepository = MockUserRepository()
        let persistence: any UserPersistenceService = MockUserPersistenceService()
        let auth: any AuthServiceProtocol = MockAuthService()
        let provider: any SocialAuthProvider = MockSocialAuthProvider()
        let exchange: any SocialAuthExchangeService = MockSocialAuthExchangeService()
        let biometrics: any BiometricAuthProvider = MockBiometricAuthService()
        let recognizer: any TextRecognizing = MockTextRecognitionService()
        let scanner: any BarcodeScanning = MockBarcodeScannerService()

        let bound: [Any] = [
            client, repository, persistence, auth, provider,
            exchange, biometrics, recognizer, scanner,
        ]

        let audited = [
            audit(MockAPIClient.self),
            audit(MockUserRepository.self),
            audit(MockUserPersistenceService.self),
            audit(MockAuthService.self),
            audit(MockSocialAuthProvider.self),
            audit(MockSocialAuthExchangeService.self),
            audit(MockBiometricAuthService.self),
            audit(MockTextRecognitionService.self),
            audit(MockBarcodeScannerService.self),
        ]

        expectAudit(audited, count: 9)
        #expect(bound.count == audited.count)
    }

    /// Finding 1: there is no composition root, only default arguments.
    ///
    /// Every construction below takes no arguments, and each one resolves a
    /// whole chain of collaborators through defaults —
    /// `LoginViewModel()` alone reaches `LiveAuthService`,
    /// `URLSessionAPIClient.shared`, `TokenStore.shared` and `KeychainWrapper`.
    ///
    /// **This test is expected to stop compiling.** Phase 8 item 2 introduces a
    /// DI container, and a container that is worth having takes those defaults
    /// off. When it does, the failure lands here, and the finding it pins should
    /// be rewritten rather than the test relaxed.
    ///
    /// The two camera view models are deliberately absent: constructing them
    /// builds a `CameraService`, and this suite does not touch capture hardware.
    /// `docs/solid.md` records that gap in the pin rather than papering it over.
    @Test("Zero-argument construction still reaches the live graph")
    func zeroArgumentConstructionStillCompiles() {
        let viewModels: [AnyObject] = [
            LoginViewModel(),
            SocialLoginViewModel(),
            BiometricAuthViewModel(),
        ]
        let services: [Any] = [
            LiveAuthService(),
            LiveUserRepository(),
            LiveSocialAuthExchangeService(),
        ]

        #expect(viewModels.count == 3)
        #expect(services.count == 3)
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
