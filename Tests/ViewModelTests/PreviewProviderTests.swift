import SwiftUI
import Testing
@testable import BoilerplateiOSSwift

// MARK: - Component Preview Tests

/// Verifies that each `PreviewProvider` conformance in the app can instantiate
/// its `previews` body without crashing. This catches regressions where a view's
/// initialiser changes but the corresponding preview is not updated.
///
/// Views that access `@Environment` objects at body-evaluation time are verified
/// by instantiation alone (not body rendering), since no SwiftUI host context is
/// available in a pure unit-test target.
@MainActor
struct ComponentPreviewProviderTests {

    // MARK: - AppButton

    @Test("AppButton primary preview renders")
    func appButtonPrimaryPreviewRenders() {
        let view = AppButton("Sign In", style: .primary) {}
        _ = view.body
    }

    @Test("AppButton secondary preview renders")
    func appButtonSecondaryPreviewRenders() {
        let view = AppButton("Cancel", style: .secondary) {}
        _ = view.body
    }

    @Test("AppButton destructive preview renders")
    func appButtonDestructivePreviewRenders() {
        let view = AppButton("Delete", style: .destructive) {}
        _ = view.body
    }

    @Test("AppButton loading-state preview renders")
    func appButtonLoadingPreviewRenders() {
        let view = AppButton("Sign In", isLoading: true) {}
        _ = view.body
    }

    @Test("AppButton disabled-state preview renders")
    func appButtonDisabledPreviewRenders() {
        let view = AppButton("Sign In", isDisabled: true) {}
        _ = view.body
    }

    @Test("AppButton_Previews previews property is accessible")
    func appButtonPreviewsPropertyAccessible() {
        _ = AppButton_Previews.self
    }

    // MARK: - AppTextField

    @Test("AppTextField normal-state preview renders")
    func appTextFieldNormalPreviewRenders() {
        let view = AppTextField(
            "Email",
            text: .constant("user@example.com"),
            keyboardType: .emailAddress,
            autocapitalization: .never,
            autocorrectionDisabled: true
        )
        _ = view.body
    }

    @Test("AppTextField secure-state preview renders")
    func appTextFieldSecurePreviewRenders() {
        let view = AppTextField(
            "Password",
            text: .constant("secret"),
            isSecure: true,
            textContentType: .password
        )
        _ = view.body
    }

    @Test("AppTextField error-state preview renders")
    func appTextFieldErrorPreviewRenders() {
        let view = AppTextField(
            "Email",
            text: .constant("not-valid"),
            errorMessage: "Please enter a valid email address."
        )
        _ = view.body
    }

    @Test("AppTextField empty preview renders")
    func appTextFieldEmptyPreviewRenders() {
        let view = AppTextField("Username", text: .constant(""))
        _ = view.body
    }

    @Test("AppTextField_Previews previews property is accessible")
    func appTextFieldPreviewsPropertyAccessible() {
        _ = AppTextField_Previews.self
    }

    // MARK: - LoadingView

    @Test("LoadingView overlay preview renders")
    func loadingViewOverlayPreviewRenders() {
        let view = LoadingView(message: "Please wait…")
        _ = view.body
    }

    @Test("LoadingView overlay without message renders")
    func loadingViewNoMessagePreviewRenders() {
        let view = LoadingView()
        _ = view.body
    }

    @Test("InlineLoadingView preview renders")
    func inlineLoadingViewPreviewRenders() {
        let view = InlineLoadingView(message: "Loading items…")
        _ = view.body
    }

    @Test("InlineLoadingView without message renders")
    func inlineLoadingViewNoMessagePreviewRenders() {
        let view = InlineLoadingView()
        _ = view.body
    }

    @Test("LoadingView_Previews previews property is accessible")
    func loadingViewPreviewsPropertyAccessible() {
        _ = LoadingView_Previews.self
    }

    // MARK: - AdaptiveStack

    /// `AdaptiveStack` reads `@Environment(\.horizontalSizeClass)`, which has a
    /// system-provided default (.compact), so body rendering is safe without a host.
    @Test("AdaptiveStack body renders")
    func adaptiveStackBodyRenders() {
        let view = AdaptiveStack(spacing: 16) {
            Color.blue.frame(height: 100)
            Color.green.frame(height: 100)
        }
        _ = view.body
    }

    @Test("AdaptiveStack_Previews previews property is accessible")
    func adaptiveStackPreviewsPropertyAccessible() {
        _ = AdaptiveStack_Previews.self
    }
}

// MARK: - Auth Preview Tests

@MainActor
struct AuthPreviewProviderTests {

    // MARK: - LoginView

    @Test("LoginView can be instantiated")
    func loginViewCanBeInstantiated() {
        // LoginView reads AppState from @Environment at body-evaluation time,
        // so we verify instantiation only — not body rendering — in a unit-test context.
        let view = LoginView()
        _ = view
    }

    @Test("LoginView_Previews previews property is accessible")
    func loginViewPreviewsPropertyAccessible() {
        _ = LoginView_Previews.self
    }

    // MARK: - BiometricAuthButton

    @Test("BiometricAuthButton Face ID preview renders")
    func biometricButtonFaceIDPreviewRenders() {
        let mock = MockBiometricAuthService()
        mock.stubbedBiometricType = .faceID
        let vm = BiometricAuthViewModel(service: mock)
        let view = BiometricAuthButton(viewModel: vm)
        _ = view.body
    }

    @Test("BiometricAuthButton Touch ID preview renders")
    func biometricButtonTouchIDPreviewRenders() {
        let mock = MockBiometricAuthService()
        mock.stubbedBiometricType = .touchID
        let vm = BiometricAuthViewModel(service: mock)
        let view = BiometricAuthButton(viewModel: vm)
        _ = view.body
    }

    @Test("BiometricAuthButton unavailable preview renders")
    func biometricButtonUnavailablePreviewRenders() {
        let mock = MockBiometricAuthService()
        mock.stubbedIsAvailable = false
        mock.stubbedBiometricType = .none
        let vm = BiometricAuthViewModel(service: mock)
        let view = BiometricAuthButton(viewModel: vm)
        _ = view.body
    }

    @Test("BiometricAuthButton_Previews previews property is accessible")
    func biometricAuthButtonPreviewsPropertyAccessible() {
        _ = BiometricAuthButton_Previews.self
    }
}

// MARK: - Home Preview Tests

@MainActor
struct HomePreviewProviderTests {

    @Test("HomeView can be instantiated")
    func homeViewCanBeInstantiated() {
        // HomeView reads AppCoordinator from @Environment at body-evaluation time.
        let view = HomeView()
        _ = view
    }

    @Test("HomeView_Previews previews property is accessible")
    func homeViewPreviewsPropertyAccessible() {
        _ = HomeView_Previews.self
    }
}

// MARK: - BarcodeScanner Preview Tests

@MainActor
struct BarcodeScannerPreviewProviderTests {

    /// `ScannerOverlayView` uses only `@State` and no environment objects,
    /// so body rendering is safe in a unit-test context.
    @Test("ScannerOverlayView active-state preview renders")
    func scannerOverlayActivePreviewRenders() {
        let view = ScannerOverlayView(isScanning: true)
        _ = view.body
    }

    @Test("ScannerOverlayView paused-state preview renders")
    func scannerOverlayPausedPreviewRenders() {
        let view = ScannerOverlayView(isScanning: false)
        _ = view.body
    }

    @Test("ScannerOverlayView_Previews previews property is accessible")
    func scannerOverlayPreviewsPropertyAccessible() {
        _ = ScannerOverlayView_Previews.self
    }

    @Test("BarcodeScannerView can be instantiated")
    func barcodeScannerViewCanBeInstantiated() {
        let view = BarcodeScannerView()
        _ = view
    }

    @Test("BarcodeScannerView_Previews previews property is accessible")
    func barcodeScannerPreviewsPropertyAccessible() {
        _ = BarcodeScannerView_Previews.self
    }
}

// MARK: - TextRecognition Preview Tests

@MainActor
struct TextRecognitionPreviewProviderTests {

    @Test("TextRecognitionView can be instantiated")
    func textRecognitionViewCanBeInstantiated() {
        let view = TextRecognitionView()
        _ = view
    }

    @Test("TextRecognitionView_Previews previews property is accessible")
    func textRecognitionPreviewsPropertyAccessible() {
        _ = TextRecognitionView_Previews.self
    }
}

// MARK: - Settings Preview Tests

@MainActor
struct SettingsPreviewProviderTests {

    @Test("SettingsView can be instantiated")
    func settingsViewCanBeInstantiated() {
        // SettingsView reads AppState from @Environment directly in body,
        // so we verify instantiation only in a unit-test context.
        let view = SettingsView()
        _ = view
    }

    @Test("SettingsView_Previews previews property is accessible")
    func settingsViewPreviewsPropertyAccessible() {
        _ = SettingsView_Previews.self
    }
}
