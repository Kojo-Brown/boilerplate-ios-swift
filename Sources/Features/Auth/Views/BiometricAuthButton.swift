import SwiftUI

/// A button that initiates Face ID or Touch ID authentication.
///
/// Renders the correct SF Symbol for the available biometric modality and
/// delegates to `BiometricAuthViewModel` for all auth logic.
///
/// Usage:
/// ```swift
/// BiometricAuthButton(viewModel: biometricVM) {
///     // Called after successful authentication
///     appState.isAuthenticated = true
/// }
/// ```
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
    let vm = BiometricAuthViewModel(service: mock)
    return BiometricAuthButton(viewModel: vm)
        .padding()
}

#Preview("Touch ID") {
    let mock = MockBiometricAuthService()
    mock.stubbedBiometricType = .touchID
    let vm = BiometricAuthViewModel(service: mock)
    return BiometricAuthButton(viewModel: vm)
        .padding()
}

#Preview("Unavailable") {
    let mock = MockBiometricAuthService()
    mock.stubbedIsAvailable = false
    mock.stubbedBiometricType = .none
    let vm = BiometricAuthViewModel(service: mock)
    return BiometricAuthButton(viewModel: vm)
        .padding()
}
