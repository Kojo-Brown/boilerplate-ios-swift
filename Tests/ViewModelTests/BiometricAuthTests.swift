import Testing
@testable import BoilerplateiOSSwift

@MainActor
struct BiometricAuthViewModelTests {
    // MARK: - Service availability

    @Test func biometricTypeReflectsService() {
        let mock = MockBiometricAuthService()
        mock.stubbedBiometricType = .faceID
        let sut = BiometricAuthViewModel(service: mock)
        #expect(sut.biometricType == .faceID)
    }

    @Test func touchIDTypeReflectsService() {
        let mock = MockBiometricAuthService()
        mock.stubbedBiometricType = .touchID
        let sut = BiometricAuthViewModel(service: mock)
        #expect(sut.biometricType == .touchID)
    }

    @Test func isAvailableReflectsService() {
        let mock = MockBiometricAuthService()
        mock.stubbedIsAvailable = true
        let sut = BiometricAuthViewModel(service: mock)
        #expect(sut.isAvailable)
    }

    @Test func isUnavailableReflectsService() {
        let mock = MockBiometricAuthService()
        mock.stubbedIsAvailable = false
        let sut = BiometricAuthViewModel(service: mock)
        #expect(!sut.isAvailable)
    }

    // MARK: - Successful authentication

    @Test func successSetsIsAuthenticated() async {
        let mock = MockBiometricAuthService()
        let sut = BiometricAuthViewModel(service: mock)
        await sut.authenticate()
        #expect(sut.isAuthenticated)
    }

    @Test func successClearsErrorMessage() async {
        let mock = MockBiometricAuthService()
        let sut = BiometricAuthViewModel(service: mock)
        await sut.authenticate()
        #expect(sut.errorMessage == nil)
    }

    @Test func successPassesReasonToService() async {
        let mock = MockBiometricAuthService()
        let sut = BiometricAuthViewModel(service: mock)
        await sut.authenticate(reason: "Unlock vault")
        #expect(mock.lastReason == "Unlock vault")
    }

    @Test func loadingIsFalseAfterSuccess() async {
        let mock = MockBiometricAuthService()
        let sut = BiometricAuthViewModel(service: mock)
        await sut.authenticate()
        #expect(!sut.isLoading)
    }

    // MARK: - Unavailable biometrics

    @Test func unavailableSkipsServiceCallAndSetsError() async {
        let mock = MockBiometricAuthService()
        mock.stubbedIsAvailable = false
        let sut = BiometricAuthViewModel(service: mock)
        await sut.authenticate()
        #expect(mock.authenticateCallCount == 0)
        #expect(sut.errorMessage != nil)
        #expect(!sut.isAuthenticated)
    }

    // MARK: - Error cases

    @Test func userCancelledDoesNotSetError() async {
        let mock = MockBiometricAuthService()
        mock.stubbedError = .userCancelled
        let sut = BiometricAuthViewModel(service: mock)
        await sut.authenticate()
        #expect(!sut.isAuthenticated)
        #expect(sut.errorMessage == nil)
    }

    @Test func lockoutSetsErrorMessage() async {
        let mock = MockBiometricAuthService()
        mock.stubbedError = .lockout
        let sut = BiometricAuthViewModel(service: mock)
        await sut.authenticate()
        #expect(!sut.isAuthenticated)
        #expect(sut.errorMessage != nil)
    }

    @Test func notEnrolledSetsErrorMessage() async {
        let mock = MockBiometricAuthService()
        mock.stubbedError = .notEnrolled
        let sut = BiometricAuthViewModel(service: mock)
        await sut.authenticate()
        #expect(sut.errorMessage != nil)
    }

    @Test func passcodeNotSetSetsErrorMessage() async {
        let mock = MockBiometricAuthService()
        mock.stubbedError = .passcodeNotSet
        let sut = BiometricAuthViewModel(service: mock)
        await sut.authenticate()
        #expect(sut.errorMessage != nil)
    }

    @Test func loadingIsFalseAfterError() async {
        let mock = MockBiometricAuthService()
        mock.stubbedError = .lockout
        let sut = BiometricAuthViewModel(service: mock)
        await sut.authenticate()
        #expect(!sut.isLoading)
    }

    // MARK: - State management

    @Test func clearErrorNilsErrorMessage() async {
        let mock = MockBiometricAuthService()
        mock.stubbedError = .lockout
        let sut = BiometricAuthViewModel(service: mock)
        await sut.authenticate()
        sut.clearError()
        #expect(sut.errorMessage == nil)
    }

    @Test func resetClearsAuthenticatedAndError() async {
        let mock = MockBiometricAuthService()
        let sut = BiometricAuthViewModel(service: mock)
        await sut.authenticate()
        #expect(sut.isAuthenticated)
        sut.reset()
        #expect(!sut.isAuthenticated)
        #expect(sut.errorMessage == nil)
    }

    @Test func authenticateCallCountIsTracked() async {
        let mock = MockBiometricAuthService()
        let sut = BiometricAuthViewModel(service: mock)
        await sut.authenticate()
        await sut.authenticate()
        #expect(mock.authenticateCallCount == 2)
    }
}

// MARK: - MockBiometricAuthService tests

struct MockBiometricAuthServiceTests {
    @Test func defaultsToFaceIDAvailable() {
        let mock = MockBiometricAuthService()
        #expect(mock.biometricType == .faceID)
        #expect(mock.isAvailable)
    }

    @Test func stubbedErrorIsThrown() async {
        let mock = MockBiometricAuthService()
        mock.stubbedError = .notAvailable
        do {
            try await mock.authenticate(reason: "test")
            Issue.record("Expected error to be thrown")
        } catch let error as BiometricAuthError {
            #expect(error == .notAvailable)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test func noErrorSucceeds() async throws {
        let mock = MockBiometricAuthService()
        try await mock.authenticate(reason: "test")
        #expect(mock.authenticateCallCount == 1)
    }
}
