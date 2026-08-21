import SwiftUI

/// A button that initiates Face ID or Touch ID authentication.
///
/// Renders the correct SF Symbol for the available biometric modality and
/// delegates to `BiometricAuthViewModel` for all auth logic.
///
/// `onSuccess` fires after a successful evaluation, and what that *means* is
/// deliberately the caller's to decide. A successful Face ID prompt says "this
/// is the device's owner"; whether that begins a session or merely re-confirms
/// one already in progress depends on which screen put the button there. On
/// `LoginView` it begins one:
///
/// ```swift
/// BiometricAuthButton(viewModel: biometricVM) {
///     events.publish(UserSignedIn(method: .biometric, email: nil))
/// }
/// ```
///
/// Somewhere guarding a destructive action, the same success would unlock that
/// action and announce nothing.
struct BiometricAuthButton: View {
    let viewModel: BiometricAuthViewModel
    var reason = "Authenticate to access your account"
    var onSuccess: (() -> Void)?

    var body: some View {
        Button {
            Task {
                await viewModel.authenticate(reason: reason)
                if viewModel.isAuthenticated {
                    onSuccess?()
                }
            }
        } label: {
            HStack(spacing: 8) {
                if viewModel.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    Image(systemName: biometricSymbol)
                        .font(.title3)
                }
                Text(biometricLabel)
                    .font(.body.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!viewModel.isAvailable || viewModel.isLoading)
        .animation(.default, value: viewModel.isLoading)
    }

    // MARK: - Private

    private var biometricSymbol: String {
        switch viewModel.biometricType {
        case .faceID:   "faceid"
        case .touchID:  "touchid"
        case .none:     "lock.fill"
        }
    }

    private var biometricLabel: String {
        switch viewModel.biometricType {
        case .faceID:   "Sign in with Face ID"
        case .touchID:  "Sign in with Touch ID"
        case .none:     "Biometrics Unavailable"
        }
    }
}

// MARK: - Preview

#Preview("Face ID") {
    let mock = MockBiometricAuthService()
    mock.stubbedBiometricType = .faceID
    let viewModel = BiometricAuthViewModel(service: mock)
    return BiometricAuthButton(viewModel: viewModel)
        .padding()
}

#Preview("Touch ID") {
    let mock = MockBiometricAuthService()
    mock.stubbedBiometricType = .touchID
    let viewModel = BiometricAuthViewModel(service: mock)
    return BiometricAuthButton(viewModel: viewModel)
        .padding()
}

#Preview("Unavailable") {
    let mock = MockBiometricAuthService()
    mock.stubbedIsAvailable = false
    mock.stubbedBiometricType = .none
    let viewModel = BiometricAuthViewModel(service: mock)
    return BiometricAuthButton(viewModel: viewModel)
        .padding()
}
