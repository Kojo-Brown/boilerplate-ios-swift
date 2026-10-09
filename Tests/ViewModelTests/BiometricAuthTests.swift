import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

/// This suite absorbed `BiometricAuthViewModelXCTests`, the XCTest mirror of
/// it. Seven of its twenty-four cases asserted something this file did not —
/// the initial state, `.none` as a biometric type, `isLoading` after the
/// unavailable path, `.systemCancelled`, `clearError()` with nothing to clear,
/// and the two halves of `reset()` that the one existing reset case does not
/// reach — and seventeen were the same assertions in the other dialect. The
/// seven are below. See `docs/testing.md`.
@MainActor
struct BiometricAuthViewModelTests {

    // MARK: - Initial state

    @Test func newViewModelIsIdleAndUnauthenticated() {
        let mock = MockBiometricAuthService()
        let sut = BiometricAuthViewModel(service: mock)

        #expect(!sut.isAuthenticated)
        #expect(!sut.isLoading)
        #expect(sut.errorMessage == nil)
    }

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

    /// A device with no enrolled biometry reports `.none` rather than an
    /// absent value, and the screen renders a different control for it, so
    /// the third case is as load-bearing as the two kinds of sensor.
    @Test func noBiometryTypeReflectsService() {
        let mock = MockBiometricAuthService()
        mock.stubbedBiometricType = BiometricType.none
        let sut = BiometricAuthViewModel(service: mock)
        #expect(sut.biometricType == BiometricType.none)
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

    @Test func loadingIsFalseAfterUnavailableBiometrics() async {
        let mock = MockBiometricAuthService()
        mock.stubbedIsAvailable = false
        let sut = BiometricAuthViewModel(service: mock)
        await sut.authenticate()
        #expect(!sut.isLoading)
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

    @Test func systemCancelledSetsErrorMessage() async {
        let mock = MockBiometricAuthService()
        mock.stubbedError = .systemCancelled
        let sut = BiometricAuthViewModel(service: mock)
        await sut.authenticate()
        #expect(sut.errorMessage != nil)
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

    @Test func clearErrorIsANoOpWhenThereIsNoError() {
        let mock = MockBiometricAuthService()
        let sut = BiometricAuthViewModel(service: mock)

        sut.clearError()

        #expect(sut.errorMessage == nil)
    }

    /// `reset()` after a *failure* is the path the retry button takes, and it
    /// is not the one `resetClearsAuthenticatedAndError` exercises: there the
    /// error was already nil before `reset()` was called, so a `reset()` that
    /// forgot to clear it would still have passed.
    @Test func resetClearsTheErrorFromAFailedAttempt() async {
        let mock = MockBiometricAuthService()
        mock.stubbedError = .lockout
        let sut = BiometricAuthViewModel(service: mock)
        await sut.authenticate()
        #expect(sut.errorMessage != nil)

        sut.reset()

        #expect(sut.errorMessage == nil)
    }

    /// The sensor the device has is not session state, so `reset()` must leave
    /// it alone — a reset that cleared it would leave the screen offering a
    /// generic passcode prompt where Touch ID was available.
    @Test func resetLeavesTheBiometricTypeAlone() {
        let mock = MockBiometricAuthService()
        mock.stubbedBiometricType = .touchID
        let sut = BiometricAuthViewModel(service: mock)

        sut.reset()

        #expect(sut.biometricType == .touchID)
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
