import Core
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
package struct BiometricAuthButton: View {
    package let viewModel: BiometricAuthViewModel
    /// What the system prompt says the app is asking for. Resolved at the
    /// point it is handed to `LAContext`, which is the one string in this file
    /// that is read out by something other than this process.
    package var reason = FeatureStrings.Biometric.reason.string
    package var onSuccess: (() -> Void)?

    package var body: some View {
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
                        .accessibilityHidden(true)
                } else {
                    // The glyph names the modality the text beside it already
                    // names. Left in the tree it is read as "faceid" — the
                    // symbol's identifier, not a word anybody says.
                    Image(systemName: biometricSymbol)
                        .font(.title3)
                        .accessibilityHidden(true)
                }
                Text(biometricLabel)
                    .font(.body.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .scaledControlHeight()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!viewModel.isAvailable || viewModel.isLoading)
        .animation(.default, value: viewModel.isLoading)
        .accessibilityLabel(Text(biometricLabel))
        .accessibilityBusy(viewModel.isLoading, doing: FeatureStrings.Biometric.authenticating)
    }

    // MARK: - Private

    private var biometricSymbol: String {
        switch viewModel.biometricType {
        case .faceID:   "faceid"
        case .touchID:  "touchid"
        case .none:     "lock.fill"
        }
    }

    private var biometricLabel: LocalizedStringResource {
        switch viewModel.biometricType {
        case .faceID:   FeatureStrings.Biometric.faceID
        case .touchID:  FeatureStrings.Biometric.touchID
        case .none:     FeatureStrings.Biometric.unavailable
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
