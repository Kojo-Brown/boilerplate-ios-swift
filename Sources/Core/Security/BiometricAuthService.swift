import Foundation
import LocalAuthentication

// MARK: - BiometricType

/// The hardware biometric modality available on the device.
enum BiometricType: Sendable, Equatable {
    case faceID
    case touchID
    case none
}

// MARK: - BiometricAuthError

enum BiometricAuthError: LocalizedError, Sendable, Equatable {
    case notAvailable
    case notEnrolled
    case userCancelled
    case userFallback
    case systemCancelled
    case passcodeNotSet
    case lockout
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:       "Biometric authentication is not available on this device."
        case .notEnrolled:        "No biometrics are enrolled. Please set up Face ID or Touch ID in Settings."
        case .userCancelled:      "Authentication was cancelled."
        case .userFallback:       "Biometric authentication was skipped."
        case .systemCancelled:    "Authentication was cancelled by the system."
        case .passcodeNotSet:     "A device passcode is required to use biometric authentication."
        case .lockout:            "Biometrics are locked out. Please enter your passcode to re-enable."
        case .failed(let reason): reason
        }
    }
}

// MARK: - BiometricAuthProvider

/// Abstraction over `LAContext` to enable deterministic testing.
protocol BiometricAuthProvider: Sendable {
    /// The type of biometric hardware available on this device.
    var biometricType: BiometricType { get }

    /// `true` when `canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` succeeds.
    var isAvailable: Bool { get }

    /// Evaluates biometric authentication with the supplied `reason` string.
    /// Throws `BiometricAuthError` on failure.
    func authenticate(reason: String) async throws
}

// MARK: - LiveBiometricAuthService

/// Production implementation backed by `LAContext`.
struct LiveBiometricAuthService: BiometricAuthProvider {
    var biometricType: BiometricType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        switch context.biometryType {
        case .faceID:   return .faceID
        case .touchID:  return .touchID
        default:        return .none
        }
    }

    var isAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    func authenticate(reason: String) async throws {
        let context = LAContext()
        var canEvalError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &canEvalError) else {
            throw mapLAError(canEvalError)
        }

        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        } catch {
            throw mapLAError(error as NSError)
        }
    }

    // MARK: - Private

    private func mapLAError(_ error: NSError?) -> BiometricAuthError {
        guard let error else { return .failed("Unknown biometric error.") }

        switch LAError.Code(rawValue: error.code) {
        case .biometryNotAvailable:             return .notAvailable
        case .biometryNotEnrolled:              return .notEnrolled
        case .userCancel:                       return .userCancelled
        case .userFallback:                     return .userFallback
        case .systemCancel, .appCancel:         return .systemCancelled
        case .passcodeNotSet:                   return .passcodeNotSet
        case .biometryLockout:                  return .lockout
        default:                                return .failed(error.localizedDescription)
        }
    }
}

// MARK: - MockBiometricAuthService

/// In-memory test double. Configure `biometricType`, `available`, and `outcome`
/// before each test; never triggers the system biometric prompt.
final class MockBiometricAuthService: BiometricAuthProvider, @unchecked Sendable {
    var stubbedBiometricType: BiometricType = .faceID
    var stubbedIsAvailable: Bool = true
    var stubbedError: BiometricAuthError?
    var authenticateCallCount = 0
    var lastReason: String?

    var biometricType: BiometricType { stubbedBiometricType }
    var isAvailable: Bool { stubbedIsAvailable }

    func authenticate(reason: String) async throws {
        authenticateCallCount += 1
        lastReason = reason
        if let error = stubbedError { throw error }
    }
}
