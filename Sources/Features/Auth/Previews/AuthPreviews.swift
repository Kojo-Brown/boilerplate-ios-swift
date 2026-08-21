import SwiftUI

// MARK: - LoginView

/// PreviewProvider-style catalogue for `LoginView`.
struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // No `.environment(AppState())` any more: `LoginView` stopped
            // reading it when its three `.onChange` blocks became one
            // publication on the event bus. An environment value a view does not
            // read is a preview that keeps compiling after the dependency it
            // was standing in for has gone.
            LoginView(container: .preview)
                .previewDisplayName("Default")

            LoginView(container: .preview)
                .preferredColorScheme(.dark)
                .previewDisplayName("Dark Mode")

            LoginView(container: .preview)
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
        let viewModel = BiometricAuthViewModel(service: mock)
        return BiometricAuthButton(viewModel: viewModel)
            .padding()
    }

    private static var touchIDPreview: some View {
        let mock = MockBiometricAuthService()
        mock.stubbedBiometricType = .touchID
        let viewModel = BiometricAuthViewModel(service: mock)
        return BiometricAuthButton(viewModel: viewModel)
            .padding()
    }

    private static var unavailablePreview: some View {
        let mock = MockBiometricAuthService()
        mock.stubbedIsAvailable = false
        mock.stubbedBiometricType = .none
        let viewModel = BiometricAuthViewModel(service: mock)
        return BiometricAuthButton(viewModel: viewModel)
            .padding()
    }
}
