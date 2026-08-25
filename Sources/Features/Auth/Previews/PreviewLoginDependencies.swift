import Core

/// The preview and test-harness stand-in for the composition root, for the one
/// screen that needs it.
///
/// `AppContainer.preview` used to be what the previews in this module reached
/// for, and it lives in a target that depends on this one, so it is no longer
/// reachable from here — which is the point: a feature that could not be
/// previewed without the whole app graph was not really a module. Every
/// collaborator below is a double this module already ships.
package struct PreviewLoginDependencies: LoginDependencies {

    /// A real bus, not a double. `EventBus` has no I/O, no policy and no failure
    /// mode, so a stub would only stop the preview's sign-in from announcing —
    /// the same argument `AppContainer.preview` makes for keeping it.
    private let bus = EventBus()

    package init() {}

    package var eventPublisher: any EventPublishing { bus }

    @MainActor
    package func makeLoginViewModel() -> LoginViewModel {
        LoginViewModel(authService: MockAuthService(), events: bus)
    }

    @MainActor
    package func makeSocialLoginViewModel() -> SocialLoginViewModel {
        SocialLoginViewModel(
            googleProvider: MockSocialAuthProvider(),
            exchangeService: MockSocialAuthExchangeService(),
            events: bus
        )
    }

    @MainActor
    package func makeBiometricAuthViewModel() -> BiometricAuthViewModel {
        BiometricAuthViewModel(service: MockBiometricAuthService())
    }
}
