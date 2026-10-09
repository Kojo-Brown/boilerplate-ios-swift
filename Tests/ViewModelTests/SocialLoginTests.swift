import AuthenticationServices
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

/// `MockSocialAuthProvider` and `MockSocialAuthExchangeService` are injected so
/// nothing here reaches the network or a system presentation anchor. Apple's
/// success path needs an `ASAuthorization`, which has no public initialiser and
/// cannot be built in a unit test; what is reachable is the nonce preparation
/// that precedes it and the failure `Result` that comes back from it, and both
/// are covered below.
///
/// This suite absorbed `SocialLoginViewModelXCTests`, the XCTest mirror of it.
/// Seven of its twenty cases asserted something this file did not — the
/// initial authentication state, that the nonce hash is lowercase hex and not
/// merely 64 characters, `.notConfigured` on the Google path, both halves of
/// the Apple failure path, and `clearError()` with nothing to clear — and
/// thirteen were the same assertions in the other dialect. They are below.
/// See `docs/testing.md`.
@MainActor
struct SocialLoginViewModelTests {

    // MARK: - Initial state

    @Test func newViewModelIsUnauthenticatedWithNoNonceAndNoError() {
        let sut = makeSUT()

        #expect(!sut.isAuthenticated)
        #expect(sut.errorMessage == nil)
        #expect(sut.appleNonceHash.isEmpty)
    }

    // MARK: - Nonce preparation

    @Test func prepareAppleNoncePopulatesNonceHash() {
        let sut = makeSUT()
        #expect(sut.appleNonceHash.isEmpty)
        sut.prepareAppleNonce()
        #expect(!sut.appleNonceHash.isEmpty)
        // SHA-256 hex string is always 64 characters
        #expect(sut.appleNonceHash.count == 64)
    }

    @Test func prepareAppleNonceProducesDifferentHashEachTime() {
        let sut = makeSUT()
        sut.prepareAppleNonce()
        let first = sut.appleNonceHash
        sut.prepareAppleNonce()
        let second = sut.appleNonceHash
        // Each nonce must be unique
        #expect(first != second)
    }

    /// The hash goes into the Apple request and the provider compares it
    /// against the nonce it is sent, so the encoding is part of the contract:
    /// 64 characters of uppercase hex is the right length and the wrong value.
    @Test func appleNonceHashIsLowercaseHex() {
        let sut = makeSUT()

        sut.prepareAppleNonce()

        #expect(sut.appleNonceHash.allSatisfy { "0123456789abcdef".contains($0) })
    }

    // MARK: - Google sign-in — success

    @Test func googleSignInSuccessSetsAuthenticated() async {
        let provider = MockSocialAuthProvider()
        provider.credential = .google(idToken: "google_id", accessToken: "google_access")
        let sut = makeSUT(googleProvider: provider)

        await sut.signInWithGoogle(anchor: ASPresentationAnchor())

        #expect(sut.isAuthenticated)
        #expect(sut.errorMessage == nil)
        #expect(!sut.isLoadingGoogle)
    }

    // MARK: - Google sign-in — cancellation

    @Test func googleSignInCancelDoesNotSetError() async {
        let provider = MockSocialAuthProvider()
        provider.shouldThrow = SocialAuthError.userCancelled
        let sut = makeSUT(googleProvider: provider)

        await sut.signInWithGoogle(anchor: ASPresentationAnchor())

        #expect(!sut.isAuthenticated)
        #expect(sut.errorMessage == nil)
    }

    // MARK: - Google sign-in — provider error

    @Test func googleSignInProviderErrorSetsErrorMessage() async {
        let provider = MockSocialAuthProvider()
        provider.shouldThrow = SocialAuthError.invalidCredential
        let sut = makeSUT(googleProvider: provider)

        await sut.signInWithGoogle(anchor: ASPresentationAnchor())

        #expect(!sut.isAuthenticated)
        #expect(sut.errorMessage != nil)
        #expect(!sut.isLoadingGoogle)
    }

    // MARK: - Google sign-in — exchange failure

    @Test func googleSignInExchangeFailureSetsErrorMessage() async {
        let exchange = MockSocialAuthExchangeService()
        exchange.shouldThrow = SocialAuthError.tokenExchangeFailed
        let sut = makeSUT(exchangeService: exchange)

        await sut.signInWithGoogle(anchor: ASPresentationAnchor())

        #expect(!sut.isAuthenticated)
        #expect(sut.errorMessage != nil)
    }

    @Test func googleSignInNotConfiguredSetsErrorMessage() async {
        let provider = MockSocialAuthProvider()
        provider.shouldThrow = SocialAuthError.notConfigured
        let sut = makeSUT(googleProvider: provider)

        await sut.signInWithGoogle(anchor: ASPresentationAnchor())

        #expect(!sut.isAuthenticated)
        #expect(sut.errorMessage != nil)
    }

    // MARK: - Apple sign-in — failure
    //
    // The success half needs an `ASAuthorization`, which cannot be constructed
    // outside the framework. The failure half takes a `Result` this test can
    // build, and it is the half that decides what the user is told.

    @Test func handleAppleResultFailureSetsErrorMessageAndClearsLoading() async {
        let sut = makeSUT()
        let result: Result<ASAuthorization, Error> = .failure(SocialAuthError.invalidCredential)

        await sut.handleAppleResult(result)

        #expect(!sut.isAuthenticated)
        #expect(sut.errorMessage != nil)
        #expect(!sut.isLoadingApple)
    }

    // MARK: - Loading state

    @Test func loadingIsFalseAfterGoogleSignInCompletes() async {
        let sut = makeSUT()
        await sut.signInWithGoogle(anchor: ASPresentationAnchor())
        #expect(!sut.isLoading)
        #expect(!sut.isLoadingGoogle)
    }

    @Test func isLoadingDefaultsToFalse() {
        let sut = makeSUT()
        #expect(!sut.isLoading)
        #expect(!sut.isLoadingApple)
        #expect(!sut.isLoadingGoogle)
    }

    // MARK: - clearError

    @Test func clearErrorNilsErrorMessage() async {
        let provider = MockSocialAuthProvider()
        provider.shouldThrow = SocialAuthError.invalidCredential
        let sut = makeSUT(googleProvider: provider)
        await sut.signInWithGoogle(anchor: ASPresentationAnchor())
        #expect(sut.errorMessage != nil)

        sut.clearError()

        #expect(sut.errorMessage == nil)
    }

    @Test func clearErrorIsANoOpWhenThereIsNoError() {
        let sut = makeSUT()

        sut.clearError()

        #expect(sut.errorMessage == nil)
    }

    // MARK: - Announcing

    /// The exchange has always answered with the signed-in `User`, and the view
    /// model used to discard it with `_ =`. Publishing the address it carries is
    /// half of why `AppState.currentUserEmail` is no longer always `nil`.
    @Test func googleSignInPublishesTheAddressTheExchangeReturned() async {
        let bus = EventBus()
        let stream = bus.events(of: UserSignedIn.self)
        let exchange = MockSocialAuthExchangeService()
        exchange.response = LoginResponse(
            accessToken: "mock-access-token",
            refreshToken: "mock-refresh-token",
            user: User(email: "grace@example.invalid", name: "Grace")
        )
        let sut = makeSUT(exchangeService: exchange, events: bus)

        await sut.signInWithGoogle(anchor: ASPresentationAnchor())
        bus.finish()

        #expect(await collect(from: stream) == [
            UserSignedIn(method: .google, email: "grace@example.invalid"),
        ])
    }

    @Test func googleSignInFailurePublishesNothing() async {
        let bus = EventBus()
        let stream = bus.events(of: UserSignedIn.self)
        let provider = MockSocialAuthProvider()
        provider.shouldThrow = SocialAuthError.invalidCredential
        let sut = makeSUT(googleProvider: provider, events: bus)

        await sut.signInWithGoogle(anchor: ASPresentationAnchor())
        bus.finish()

        #expect(await collect(from: stream).isEmpty)
    }

    // MARK: - Factory

    private func makeSUT(
        googleProvider: MockSocialAuthProvider = MockSocialAuthProvider(),
        exchangeService: MockSocialAuthExchangeService = MockSocialAuthExchangeService(),
        events: any EventPublishing = EventBus()
    ) -> SocialLoginViewModel {
        SocialLoginViewModel(
            googleProvider: googleProvider,
            exchangeService: exchangeService,
            events: events
        )
    }
}

// MARK: - SocialAuthError tests

struct SocialAuthErrorTests {
    @Test func allErrorDescriptionsAreNonEmpty() {
        let errors: [SocialAuthError] = [
            .invalidCredential, .userCancelled, .notConfigured, .tokenExchangeFailed,
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test func errorsCompareByCase() {
        #expect(SocialAuthError.userCancelled == SocialAuthError.userCancelled)
        #expect(SocialAuthError.invalidCredential == SocialAuthError.invalidCredential)
        #expect(SocialAuthError.invalidCredential != SocialAuthError.userCancelled)
        #expect(SocialAuthError.notConfigured != SocialAuthError.tokenExchangeFailed)
    }
}

// MARK: - SocialLoginRequest encoding tests

struct SocialLoginRequestTests {
    @Test func appleRequestEncodesAllFields() throws {
        let request = SocialLoginRequest(
            provider: "apple",
            identityToken: "tok",
            authorizationCode: "code",
            nonce: "abc123",
            givenName: "Jane",
            familyName: "Doe"
        )
        let data = try JSONEncoder.apiEncoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["provider"] as? String == "apple")
        #expect(json?["identity_token"] as? String == "tok")
        #expect(json?["authorization_code"] as? String == "code")
        #expect(json?["nonce"] as? String == "abc123")
        #expect(json?["given_name"] as? String == "Jane")
        #expect(json?["family_name"] as? String == "Doe")
    }

    @Test func googleRequestEncodesRequiredFields() throws {
        let request = SocialLoginRequest(
            provider: "google",
            identityToken: "gtok",
            authorizationCode: nil,
            nonce: nil,
            givenName: nil,
            familyName: nil
        )
        let data = try JSONEncoder.apiEncoder.encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["provider"] as? String == "google")
        #expect(json?["identity_token"] as? String == "gtok")
    }

    @Test func providerFieldIsSnakeCaseEncoded() throws {
        let request = SocialLoginRequest(
            provider: "apple",
            identityToken: "tok",
            authorizationCode: nil,
            nonce: nil,
            givenName: nil,
            familyName: nil
        )
        let data = try JSONEncoder.apiEncoder.encode(request)
        // The raw JSON keys should be snake_case per CodingKeys
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        #expect(jsonString.contains("identity_token"))
        #expect(!jsonString.contains("identityToken"))
    }
}
