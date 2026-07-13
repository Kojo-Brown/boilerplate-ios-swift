import XCTest
@testable import BoilerplateiOSSwift

/// XCTest suite for `LoginViewModel` demonstrating `@MainActor` isolation.
///
/// All methods on this class inherit the main-actor context from the class annotation,
/// allowing direct mutation of `@Observable @MainActor` ViewModels without `await`.
/// Async test methods (suffixed with no special marker) are supported natively in
/// XCTest via `async` function signatures — the test runner awaits completion.
@MainActor
final class LoginViewModelXCTests: XCTestCase {

    // MARK: - Initial state

    func testInitialStateIsEmpty() {
        let sut = LoginViewModel(authService: MockAuthService())
        XCTAssertTrue(sut.email.isEmpty)
        XCTAssertTrue(sut.password.isEmpty)
        XCTAssertFalse(sut.isLoading)
        XCTAssertNil(sut.errorMessage)
        XCTAssertFalse(sut.isAuthenticated)
    }

    func testEmptyFormIsInvalid() {
        let sut = LoginViewModel(authService: MockAuthService())
        XCTAssertFalse(sut.isFormValid)
    }

    // MARK: - Form validation

    func testInvalidEmailFormatFailsValidation() {
        let sut = LoginViewModel(authService: MockAuthService())
        sut.email = "notanemail"
        sut.password = "password123"
        XCTAssertFalse(sut.isFormValid)
    }

    func testEmailWithoutAtSignFailsValidation() {
        let sut = LoginViewModel(authService: MockAuthService())
        sut.email = "userexample.com"
        sut.password = "password123"
        XCTAssertFalse(sut.isFormValid)
    }

    func testWhitespaceOnlyEmailFailsValidation() {
        let sut = LoginViewModel(authService: MockAuthService())
        sut.email = "   "
        sut.password = "password123"
        XCTAssertFalse(sut.isFormValid)
    }

    func testPasswordUnderEightCharsFailsValidation() {
        let sut = LoginViewModel(authService: MockAuthService())
        sut.email = "user@example.com"
        sut.password = "abc"
        XCTAssertFalse(sut.isFormValid)
    }

    func testPasswordExactlyEightCharsIsValid() {
        let sut = LoginViewModel(authService: MockAuthService())
        sut.email = "user@example.com"
        sut.password = "12345678"
        XCTAssertTrue(sut.isFormValid)
    }

    func testValidCredentialsPassValidation() {
        let sut = LoginViewModel(authService: MockAuthService())
        sut.email = "user@example.com"
        sut.password = "password123"
        XCTAssertTrue(sut.isFormValid)
    }

    func testEmailWithSubdomainIsValid() {
        let sut = LoginViewModel(authService: MockAuthService())
        sut.email = "user@mail.example.com"
        sut.password = "password123"
        XCTAssertTrue(sut.isFormValid)
    }

    // MARK: - Login — success

    func testSuccessfulLoginSetsAuthenticated() async {
        let service = MockAuthService()
        service.shouldSucceed = true
        let sut = LoginViewModel(authService: service)
        sut.email = "user@example.com"
        sut.password = "password123"

        await sut.login()

        XCTAssertTrue(sut.isAuthenticated)
        XCTAssertNil(sut.errorMessage)
    }

    func testIsLoadingIsFalseAfterSuccessfulLogin() async {
        let service = MockAuthService()
        service.shouldSucceed = true
        let sut = LoginViewModel(authService: service)
        sut.email = "user@example.com"
        sut.password = "password123"

        await sut.login()

        XCTAssertFalse(sut.isLoading)
    }

    // MARK: - Login — failure

    func testFailedLoginSetsErrorMessage() async {
        let service = MockAuthService()
        service.shouldSucceed = false
        let sut = LoginViewModel(authService: service)
        sut.email = "user@example.com"
        sut.password = "password123"

        await sut.login()

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertNotNil(sut.errorMessage)
        XCTAssertFalse(sut.isLoading)
    }

    func testInvalidFormSkipsNetworkCall() async {
        let service = MockAuthService()
        let sut = LoginViewModel(authService: service)
        // Leave credentials empty — form is invalid

        await sut.login()

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertFalse(sut.isLoading)
    }

    // MARK: - clearError

    func testClearErrorNilsErrorMessage() async {
        let service = MockAuthService()
        service.shouldSucceed = false
        let sut = LoginViewModel(authService: service)
        sut.email = "user@example.com"
        sut.password = "password123"
        await sut.login()
        XCTAssertNotNil(sut.errorMessage)

        sut.clearError()

        XCTAssertNil(sut.errorMessage)
    }

    func testClearErrorIsNoOpWhenThereIsNoError() {
        let sut = LoginViewModel(authService: MockAuthService())
        sut.clearError()
        XCTAssertNil(sut.errorMessage)
    }
}
