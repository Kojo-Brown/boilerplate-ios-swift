import AuthenticationServices
import XCTest
@testable import BoilerplateiOSSwift

/// XCTest suite for `SocialLoginViewModel` with `@MainActor` isolation.
///
/// `MockSocialAuthProvider` and `MockSocialAuthExchangeService` are injected to
/// avoid real network calls and system presentation anchors. Apple Sign-In result
/// handling requires `ASAuthorization` objects that cannot be created in unit tests;
/// those flows are covered by the nonce preparation tests and error path tests.
@MainActor
final class SocialLoginViewModelXCTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT(
        googleProvider: MockSocialAuthProvider = MockSocialAuthProvider(),
        exchangeService: MockSocialAuthExchangeService = MockSocialAuthExchangeService()
    ) -> SocialLoginViewModel {
        SocialLoginViewModel(googleProvider: googleProvider, exchangeService: exchangeService)
    }

    // MARK: - Initial state

    func testInitialIsLoadingIsFalse() {
        let sut = makeSUT()
        XCTAssertFalse(sut.isLoading)
    }

    func testInitialIsLoadingAppleIsFalse() {
        let sut = makeSUT()
        XCTAssertFalse(sut.isLoadingApple)
    }

    func testInitialIsLoadingGoogleIsFalse() {
        let sut = makeSUT()
        XCTAssertFalse(sut.isLoadingGoogle)
    }

    func testInitialErrorMessageIsNil() {
        let sut = makeSUT()
        XCTAssertNil(sut.errorMessage)
    }

    func testInitialIsAuthenticatedIsFalse() {
        let sut = makeSUT()
        XCTAssertFalse(sut.isAuthenticated)
    }

    func testInitialAppleNonceHashIsEmpty() {
        let sut = makeSUT()
        XCTAssertTrue(sut.appleNonceHash.isEmpty)
    }

    // MARK: - Nonce preparation

    func testPrepareAppleNoncePopulatesNonceHash() {
        let sut = makeSUT()

        sut.prepareAppleNonce()

        XCTAssertFalse(sut.appleNonceHash.isEmpty)
    }

    func testAppleNonceHashIsSHA256HexLength() {
        let sut = makeSUT()

        sut.prepareAppleNonce()

        XCTAssertEqual(sut.appleNonceHash.count, 64)
    }

    func testPrepareAppleNonceGeneratesUniqueHashEachCall() {
        let sut = makeSUT()
        sut.prepareAppleNonce()
        let first = sut.appleNonceHash

        sut.prepareAppleNonce()
        let second = sut.appleNonceHash

        XCTAssertNotEqual(first, second)
    }

    func testAppleNonceHashContainsOnlyHexCharacters() {
        let sut = makeSUT()
        sut.prepareAppleNonce()
        let hexCharacterSet = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertTrue(sut.appleNonceHash.unicodeScalars.allSatisfy { hexCharacterSet.contains($0) })
    }

    // MARK: - Google sign-in — success

    func testGoogleSignInSuccessSetsAuthenticated() async {
        let provider = MockSocialAuthProvider()
        provider.credential = .google(idToken: "google_id", accessToken: "google_access")
        let sut = makeSUT(googleProvider: provider)

        await sut.signInWithGoogle(anchor: ASPresentationAnchor())

        XCTAssertTrue(sut.isAuthenticated)
        XCTAssertNil(sut.errorMessage)
    }

    func testGoogleSignInSuccessClearsLoadingFlag() async {
        let sut = makeSUT()

        await sut.signInWithGoogle(anchor: ASPresentationAnchor())

        XCTAssertFalse(sut.isLoadingGoogle)
        XCTAssertFalse(sut.isLoading)
    }

    // MARK: - Google sign-in — cancellation

    func testGoogleSignInCancelDoesNotSetError() async {
        let provider = MockSocialAuthProvider()
        provider.shouldThrow = SocialAuthError.userCancelled
        let sut = makeSUT(googleProvider: provider)

        await sut.signInWithGoogle(anchor: ASPresentationAnchor())

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertNil(sut.errorMessage)
    }

    // MARK: - Google sign-in — errors

    func testGoogleSignInProviderErrorSetsErrorMessage() async {
        let provider = MockSocialAuthProvider()
        provider.shouldThrow = SocialAuthError.invalidCredential
        let sut = makeSUT(googleProvider: provider)

        await sut.signInWithGoogle(anchor: ASPresentationAnchor())

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertNotNil(sut.errorMessage)
        XCTAssertFalse(sut.isLoadingGoogle)
    }

    func testGoogleSignInExchangeFailureSetsErrorMessage() async {
        let exchange = MockSocialAuthExchangeService()
        exchange.shouldThrow = SocialAuthError.tokenExchangeFailed
        let sut = makeSUT(exchangeService: exchange)

        await sut.signInWithGoogle(anchor: ASPresentationAnchor())

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertNotNil(sut.errorMessage)
    }

    func testGoogleSignInNotConfiguredSetsErrorMessage() async {
        let provider = MockSocialAuthProvider()
        provider.shouldThrow = SocialAuthError.notConfigured
        let sut = makeSUT(googleProvider: provider)

        await sut.signInWithGoogle(anchor: ASPresentationAnchor())

        XCTAssertNotNil(sut.errorMessage)
    }

    // MARK: - Apple Sign-In error path

    func testHandleAppleResultWithFailureSetsErrorMessage() async {
        let sut = makeSUT()
        let error = SocialAuthError.invalidCredential
        let result: Result<ASAuthorization, Error> = .failure(error)

        await sut.handleAppleResult(result)

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertNotNil(sut.errorMessage)
    }

    func testHandleAppleResultLoadingFalseAfterFailure() async {
        let sut = makeSUT()
        let result: Result<ASAuthorization, Error> = .failure(SocialAuthError.invalidCredential)

        await sut.handleAppleResult(result)

        XCTAssertFalse(sut.isLoadingApple)
    }

    // MARK: - clearError

    func testClearErrorNilsErrorMessage() async {
        let provider = MockSocialAuthProvider()
        provider.shouldThrow = SocialAuthError.invalidCredential
        let sut = makeSUT(googleProvider: provider)
        await sut.signInWithGoogle(anchor: ASPresentationAnchor())
        XCTAssertNotNil(sut.errorMessage)

        sut.clearError()

        XCTAssertNil(sut.errorMessage)
    }

    func testClearErrorIsNoOpWhenNoError() {
        let sut = makeSUT()
        sut.clearError()
        XCTAssertNil(sut.errorMessage)
    }
}
