import XCTest
@testable import BoilerplateiOSSwift

/// XCTest suite for `BiometricAuthViewModel` with `@MainActor` isolation.
///
/// `MockBiometricAuthService` is injected to avoid triggering the system biometric
/// prompt. The mock is configured per-test via its stubbed properties.
@MainActor
final class BiometricAuthViewModelXCTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT(
        biometricType: BiometricType = .faceID,
        isAvailable: Bool = true,
        stubbedError: BiometricAuthError? = nil
    ) -> (sut: BiometricAuthViewModel, mock: MockBiometricAuthService) {
        let mock = MockBiometricAuthService()
        mock.stubbedBiometricType = biometricType
        mock.stubbedIsAvailable = isAvailable
        mock.stubbedError = stubbedError
        let sut = BiometricAuthViewModel(service: mock)
        return (sut, mock)
    }

    // MARK: - Service reflection

    func testBiometricTypeReflectsServiceFaceID() {
        let (sut, _) = makeSUT(biometricType: .faceID)
        XCTAssertEqual(sut.biometricType, .faceID)
    }

    func testBiometricTypeReflectsServiceTouchID() {
        let (sut, _) = makeSUT(biometricType: .touchID)
        XCTAssertEqual(sut.biometricType, .touchID)
    }

    func testBiometricTypeReflectsNoneWhenUnavailable() {
        let (sut, _) = makeSUT(biometricType: .none)
        XCTAssertEqual(sut.biometricType, .none)
    }

    func testIsAvailableTrueReflectsService() {
        let (sut, _) = makeSUT(isAvailable: true)
        XCTAssertTrue(sut.isAvailable)
    }

    func testIsAvailableFalseReflectsService() {
        let (sut, _) = makeSUT(isAvailable: false)
        XCTAssertFalse(sut.isAvailable)
    }

    // MARK: - Initial state

    func testInitialStateIsNotAuthenticated() {
        let (sut, _) = makeSUT()
        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertFalse(sut.isLoading)
        XCTAssertNil(sut.errorMessage)
    }

    // MARK: - Successful authentication

    func testSuccessfulAuthSetsAuthenticated() async {
        let (sut, _) = makeSUT()

        await sut.authenticate()

        XCTAssertTrue(sut.isAuthenticated)
    }

    func testSuccessfulAuthClearsErrorMessage() async {
        let (sut, _) = makeSUT()

        await sut.authenticate()

        XCTAssertNil(sut.errorMessage)
    }

    func testIsLoadingIsFalseAfterSuccessfulAuth() async {
        let (sut, _) = makeSUT()

        await sut.authenticate()

        XCTAssertFalse(sut.isLoading)
    }

    func testSuccessfulAuthForwardsReasonToService() async {
        let (sut, mock) = makeSUT()

        await sut.authenticate(reason: "Unlock vault")

        XCTAssertEqual(mock.lastReason, "Unlock vault")
    }

    func testAuthCallCountIncreasesPerCall() async {
        let (sut, mock) = makeSUT()

        await sut.authenticate()
        await sut.authenticate()

        XCTAssertEqual(mock.authenticateCallCount, 2)
    }

    // MARK: - Unavailable biometrics

    func testUnavailableSkipsServiceCallAndSetsError() async {
        let (sut, mock) = makeSUT(isAvailable: false)

        await sut.authenticate()

        XCTAssertEqual(mock.authenticateCallCount, 0)
        XCTAssertNotNil(sut.errorMessage)
        XCTAssertFalse(sut.isAuthenticated)
    }

    func testIsLoadingIsFalseAfterUnavailableAuth() async {
        let (sut, _) = makeSUT(isAvailable: false)

        await sut.authenticate()

        XCTAssertFalse(sut.isLoading)
    }

    // MARK: - Error scenarios

    func testUserCancelledDoesNotSetErrorMessage() async {
        let (sut, _) = makeSUT(stubbedError: .userCancelled)

        await sut.authenticate()

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertNil(sut.errorMessage)
    }

    func testLockoutSetsErrorMessage() async {
        let (sut, _) = makeSUT(stubbedError: .lockout)

        await sut.authenticate()

        XCTAssertFalse(sut.isAuthenticated)
        XCTAssertNotNil(sut.errorMessage)
    }

    func testNotEnrolledSetsErrorMessage() async {
        let (sut, _) = makeSUT(stubbedError: .notEnrolled)

        await sut.authenticate()

        XCTAssertNotNil(sut.errorMessage)
    }

    func testPasscodeNotSetSetsErrorMessage() async {
        let (sut, _) = makeSUT(stubbedError: .passcodeNotSet)

        await sut.authenticate()

        XCTAssertNotNil(sut.errorMessage)
    }

    func testSystemCancelledSetsErrorMessage() async {
        let (sut, _) = makeSUT(stubbedError: .systemCancelled)

        await sut.authenticate()

        XCTAssertNotNil(sut.errorMessage)
    }

    func testIsLoadingIsFalseAfterError() async {
        let (sut, _) = makeSUT(stubbedError: .lockout)

        await sut.authenticate()

        XCTAssertFalse(sut.isLoading)
    }

    // MARK: - State management

    func testClearErrorNilsErrorMessage() async {
        let (sut, _) = makeSUT(stubbedError: .lockout)
        await sut.authenticate()
        XCTAssertNotNil(sut.errorMessage)

        sut.clearError()

        XCTAssertNil(sut.errorMessage)
    }

    func testClearErrorIsNoOpWhenNoError() {
        let (sut, _) = makeSUT()
        sut.clearError()
        XCTAssertNil(sut.errorMessage)
    }

    func testResetClearsAuthenticatedFlag() async {
        let (sut, _) = makeSUT()
        await sut.authenticate()
        XCTAssertTrue(sut.isAuthenticated)

        sut.reset()

        XCTAssertFalse(sut.isAuthenticated)
    }

    func testResetClearsErrorMessage() async {
        let (sut, _) = makeSUT(stubbedError: .lockout)
        await sut.authenticate()
        XCTAssertNotNil(sut.errorMessage)

        sut.reset()

        XCTAssertNil(sut.errorMessage)
    }

    func testResetDoesNotAffectBiometricType() {
        let (sut, _) = makeSUT(biometricType: .touchID)

        sut.reset()

        XCTAssertEqual(sut.biometricType, .touchID)
    }
}
