import Core
import Foundation
import Observation

/// Drives the biometric authentication flow.
///
/// Designed for injection — pass a `MockBiometricAuthService` in tests to avoid
/// triggering the system prompt.
@Observable
@MainActor
package final class BiometricAuthViewModel {
    package var isAuthenticated = false
    package var isLoading = false
    package var errorMessage: String?

    package var biometricType: BiometricType { service.biometricType }
    package var isAvailable: Bool { service.isAvailable }

    private let service: any BiometricAuthProvider

    /// Built by `AppContainer.makeBiometricAuthViewModel()`; no default.
    package init(service: any BiometricAuthProvider) {
        self.service = service
    }

    // MARK: - Actions

    /// Initiates the biometric evaluation with `reason` surfaced to the user.
    package func authenticate(reason: String = "Authenticate to access your account") async {
        guard isAvailable else {
            errorMessage = BiometricAuthError.notAvailable.localizedDescription
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await service.authenticate(reason: reason)
            isAuthenticated = true
        } catch let error as BiometricAuthError {
            if error != .userCancelled {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    package func clearError() {
        errorMessage = nil
    }

    package func reset() {
        isAuthenticated = false
        errorMessage = nil
    }
}
