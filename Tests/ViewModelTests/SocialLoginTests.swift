import AuthenticationServices
import Testing
@testable import BoilerplateiOSSwift

@MainActor
struct SocialLoginViewModelTests {
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

    // MARK: - Factory

    private func makeSUT(
        googleProvider: MockSocialAuthProvider = MockSocialAuthProvider(),
        exchangeService: MockSocialAuthExchangeService = MockSocialAuthExchangeService()
    ) -> SocialLoginViewModel {
        SocialLoginViewModel(googleProvider: googleProvider, exchangeService: exchangeService)
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
