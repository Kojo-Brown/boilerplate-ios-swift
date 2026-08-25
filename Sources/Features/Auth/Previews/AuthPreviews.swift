import Core
import SwiftUI

// MARK: - LoginView

/// PreviewProvider-style catalogue for `LoginView`.
package struct LoginView_Previews: PreviewProvider {
    package static var previews: some View {
        Group {
            // No `.environment(AppState())` any more: `LoginView` stopped
            // reading it when its three `.onChange` blocks became one
            // publication on the event bus. An environment value a view does not
            // read is a preview that keeps compiling after the dependency it
            // was standing in for has gone.
            LoginView(dependencies: PreviewLoginDependencies())
                .previewDisplayName("Default")

            LoginView(dependencies: PreviewLoginDependencies())
                .preferredColorScheme(.dark)
                .previewDisplayName("Dark Mode")

            LoginView(dependencies: PreviewLoginDependencies())
                .previewDevice(PreviewDevice(rawValue: "iPhone SE (3rd generation)"))
                .previewDisplayName("iPhone SE")
        }
    }
}

// MARK: - BiometricAuthButton

/// PreviewProvider-style catalogue for `BiometricAuthButton`.
package struct BiometricAuthButton_Previews: PreviewProvider {
    package static var previews: some View {
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
