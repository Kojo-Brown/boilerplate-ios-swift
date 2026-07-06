import Testing
@testable import BoilerplateiOSSwift

@MainActor
struct LoginViewModelTests {
    // MARK: - Form validation

    @Test func emptyEmailAndPasswordIsInvalid() {
        let sut = LoginViewModel(authService: MockAuthService())
        #expect(!sut.isFormValid)
    }

    @Test func invalidEmailFormatIsInvalid() {
        let sut = LoginViewModel(authService: MockAuthService())
        sut.email = "notanemail"
        sut.password = "password123"
        #expect(!sut.isFormValid)
    }

    @Test func shortPasswordIsInvalid() {
        let sut = LoginViewModel(authService: MockAuthService())
        sut.email = "user@example.com"
        sut.password = "abc"
        #expect(!sut.isFormValid)
    }

    @Test func validCredentialsPassValidation() {
        let sut = LoginViewModel(authService: MockAuthService())
        sut.email = "user@example.com"
        sut.password = "password123"
        #expect(sut.isFormValid)
    }

    // MARK: - Login flow

    @Test func successfulLoginSetsAuthenticated() async {
        let service = MockAuthService()
        service.shouldSucceed = true
        let sut = LoginViewModel(authService: service)
        sut.email = "user@example.com"
        sut.password = "password123"

        await sut.login()

        #expect(sut.isAuthenticated)
        #expect(sut.errorMessage == nil)
    }

    @Test func failedLoginSetsErrorMessage() async {
        let service = MockAuthService()
        service.shouldSucceed = false
        let sut = LoginViewModel(authService: service)
        sut.email = "user@example.com"
        sut.password = "password123"

        await sut.login()

        #expect(!sut.isAuthenticated)
        #expect(sut.errorMessage != nil)
    }

    @Test func loadingIsFalsAfterLoginCompletes() async {
        let sut = LoginViewModel(authService: MockAuthService())
        sut.email = "user@example.com"
        sut.password = "password123"

        await sut.login()

        #expect(!sut.isLoading)
    }

    @Test func invalidFormSkipsNetworkCall() async {
        let service = MockAuthService()
        let sut = LoginViewModel(authService: service)
        // leave email/password empty — form is invalid

        await sut.login()

        #expect(!sut.isAuthenticated)
        #expect(!sut.isLoading)
    }

    @Test func clearErrorNilsErrorMessage() async {
        let service = MockAuthService()
        service.shouldSucceed = false
        let sut = LoginViewModel(authService: service)
        sut.email = "user@example.com"
        sut.password = "password123"
        await sut.login()

        sut.clearError()

        #expect(sut.errorMessage == nil)
    }
}
