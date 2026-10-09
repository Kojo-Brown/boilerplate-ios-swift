import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

/// All methods inherit the main-actor context from the suite annotation, so an
/// `@Observable @MainActor` view model can be mutated directly and read back
/// without an `await`; the `async` cases await only the action under test.
///
/// This suite absorbed `LoginViewModelXCTests`, the XCTest mirror of it. Six of
/// its fifteen cases were assertions this file did not make — the initial
/// state, two more malformed-email shapes, the eight-character password
/// boundary, a subdomain address, and `clearError()` with nothing to clear —
/// and nine were the same assertions in the other dialect. The six are below.
/// See `docs/testing.md`.
@MainActor
struct LoginViewModelTests {

    // MARK: - Initial state

    @Test func newViewModelIsEmptyAndUnauthenticated() {
        let sut = LoginViewModel(authService: MockAuthService(), events: EventBus())

        #expect(sut.email.isEmpty)
        #expect(sut.password.isEmpty)
        #expect(!sut.isLoading)
        #expect(sut.errorMessage == nil)
        #expect(!sut.isAuthenticated)
    }

    // MARK: - Form validation

    @Test func emptyEmailAndPasswordIsInvalid() {
        let sut = LoginViewModel(authService: MockAuthService(), events: EventBus())
        #expect(!sut.isFormValid)
    }

    @Test func invalidEmailFormatIsInvalid() {
        let sut = LoginViewModel(authService: MockAuthService(), events: EventBus())
        sut.email = "notanemail"
        sut.password = "password123"
        #expect(!sut.isFormValid)
    }

    @Test func shortPasswordIsInvalid() {
        let sut = LoginViewModel(authService: MockAuthService(), events: EventBus())
        sut.email = "user@example.com"
        sut.password = "abc"
        #expect(!sut.isFormValid)
    }

    @Test func validCredentialsPassValidation() {
        let sut = LoginViewModel(authService: MockAuthService(), events: EventBus())
        sut.email = "user@example.com"
        sut.password = "password123"
        #expect(sut.isFormValid)
    }

    @Test func emailWithoutAnAtSignIsInvalid() {
        let sut = LoginViewModel(authService: MockAuthService(), events: EventBus())
        sut.email = "userexample.com"
        sut.password = "password123"
        #expect(!sut.isFormValid)
    }

    @Test func whitespaceOnlyEmailIsInvalid() {
        let sut = LoginViewModel(authService: MockAuthService(), events: EventBus())
        sut.email = "   "
        sut.password = "password123"
        #expect(!sut.isFormValid)
    }

    /// Eight is the shortest accepted password, so it is the one length worth
    /// asserting: `>=` written as `>` passes every other case in this suite.
    @Test func passwordOfExactlyEightCharactersIsValid() {
        let sut = LoginViewModel(authService: MockAuthService(), events: EventBus())
        sut.email = "user@example.com"
        sut.password = "12345678"
        #expect(sut.isFormValid)
    }

    @Test func emailWithASubdomainIsValid() {
        let sut = LoginViewModel(authService: MockAuthService(), events: EventBus())
        sut.email = "user@mail.example.com"
        sut.password = "password123"
        #expect(sut.isFormValid)
    }

    // MARK: - Login flow

    @Test func successfulLoginSetsAuthenticated() async {
        let service = MockAuthService()
        service.shouldSucceed = true
        let sut = LoginViewModel(authService: service, events: EventBus())
        sut.email = "user@example.com"
        sut.password = "password123"

        await sut.login()

        #expect(sut.isAuthenticated)
        #expect(sut.errorMessage == nil)
    }

    @Test func failedLoginSetsErrorMessage() async {
        let service = MockAuthService()
        service.shouldSucceed = false
        let sut = LoginViewModel(authService: service, events: EventBus())
        sut.email = "user@example.com"
        sut.password = "password123"

        await sut.login()

        #expect(!sut.isAuthenticated)
        #expect(sut.errorMessage != nil)
    }

    @Test func loadingIsFalseAfterLoginCompletes() async {
        let sut = LoginViewModel(authService: MockAuthService(), events: EventBus())
        sut.email = "user@example.com"
        sut.password = "password123"

        await sut.login()

        #expect(!sut.isLoading)
    }

    @Test func invalidFormSkipsNetworkCall() async {
        let service = MockAuthService()
        let sut = LoginViewModel(authService: service, events: EventBus())
        // leave email/password empty — form is invalid

        await sut.login()

        #expect(!sut.isAuthenticated)
        #expect(!sut.isLoading)
    }

    @Test func clearErrorNilsErrorMessage() async {
        let service = MockAuthService()
        service.shouldSucceed = false
        let sut = LoginViewModel(authService: service, events: EventBus())
        sut.email = "user@example.com"
        sut.password = "password123"
        await sut.login()

        sut.clearError()

        #expect(sut.errorMessage == nil)
    }

    @Test func clearErrorIsANoOpWhenThereIsNoError() {
        let sut = LoginViewModel(authService: MockAuthService(), events: EventBus())

        sut.clearError()

        #expect(sut.errorMessage == nil)
    }

    // MARK: - Announcing

    /// `isAuthenticated` says what happened on this screen; the event says what
    /// happened to the app. `LoginView` used to bridge the two with an
    /// `.onChange` that assigned `appState.isAuthenticated` and nothing else.
    @Test func successfulLoginPublishesUserSignedIn() async {
        let bus = EventBus()
        let stream = bus.events(of: UserSignedIn.self)
        let service = MockAuthService()
        service.shouldSucceed = true
        let sut = LoginViewModel(authService: service, events: bus)
        sut.email = "user@example.invalid"
        sut.password = "password123"

        await sut.login()
        bus.finish()

        #expect(await collect(from: stream) == [
            UserSignedIn(method: .password, email: "user@example.invalid"),
        ])
    }

    @Test func failedLoginPublishesNothing() async {
        let bus = EventBus()
        let stream = bus.events(of: UserSignedIn.self)
        let service = MockAuthService()
        service.shouldSucceed = false
        let sut = LoginViewModel(authService: service, events: bus)
        sut.email = "user@example.invalid"
        sut.password = "password123"

        await sut.login()
        bus.finish()

        #expect(await collect(from: stream).isEmpty)
    }

    /// An invalid form never reaches the service, so it must never reach the bus
    /// either — `login()` returns at its `guard` before anything happens.
    @Test func invalidFormPublishesNothing() async {
        let bus = EventBus()
        let stream = bus.events(of: UserSignedIn.self)
        let sut = LoginViewModel(authService: MockAuthService(), events: bus)
        sut.email = "notanemail"
        sut.password = "abc"

        await sut.login()
        bus.finish()

        #expect(await collect(from: stream).isEmpty)
    }
}
