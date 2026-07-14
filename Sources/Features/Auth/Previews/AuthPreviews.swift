import SwiftUI

// MARK: - LoginView

/// PreviewProvider-style catalogue for `LoginView`.
struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            LoginView()
                .environment(AppState())
                .previewDisplayName("Default")

            LoginView()
                .environment(AppState())
                .preferredColorScheme(.dark)
                .previewDisplayName("Dark Mode")

            LoginView()
                .environment(AppState())
                .previewDevice(PreviewDevice(rawValue: "iPhone SE (3rd generation)"))
                .previewDisplayName("iPhone SE")
        }
    }
}

// MARK: - BiometricAuthButton

/// PreviewProvider-style catalogue for `BiometricAuthButton`.
struct BiometricAuthButton_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            faceIDPreview
                .previewDisplayName("Face ID")

            touchIDPreview
                .previewDisplayName("Touch ID")

            unavailablePreview
                .previewDisplayName("Unavailable")
        }
    }

    private static var faceIDPreview: some View {
        let mock = MockBiometricAuthService()
        mock.stubbedBiometricType = .faceID
        let vm = BiometricAuthViewModel(service: mock)
        return BiometricAuthButton(viewModel: vm)
            .padding()
    }

    private static var touchIDPreview: some View {
        let mock = MockBiometricAuthService()
        mock.stubbedBiometricType = .touchID
        let vm = BiometricAuthViewModel(service: mock)
        return BiometricAuthButton(viewModel: vm)
            .padding()
    }

    private static var unavailablePreview: some View {
        let mock = MockBiometricAuthService()
        mock.stubbedIsAvailable = false
        mock.stubbedBiometricType = .none
        let vm = BiometricAuthViewModel(service: mock)
        return BiometricAuthButton(viewModel: vm)
            .padding()
    }
}
