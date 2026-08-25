import Core

/// What `LoginView` needs from the composition root, stated by the screen that
/// needs it.
///
/// Before the package was split into targets, this screen took the whole
/// `AppContainer`. That compiled because everything was one module, and it was
/// the one edge that made the split impossible: `AppContainer` names five
/// screens, so a feature that names `AppContainer` names every other feature
/// through it. Nothing was wrong with the *ergonomics* of passing the container
/// — `AppNavigationView` still passes it, and still writes `container:` once —
/// but the dependency has to point the other way for the modules to come apart.
///
/// So the screen declares the four things it uses and the root conforms. That is
/// interface segregation in the plain sense: `LoginView` cannot reach a camera
/// or a sync strategy through this, and a change to either cannot reach
/// `LoginView`.
package protocol LoginDependencies {

    @MainActor func makeLoginViewModel() -> LoginViewModel

    @MainActor func makeSocialLoginViewModel() -> SocialLoginViewModel

    @MainActor func makeBiometricAuthViewModel() -> BiometricAuthViewModel

    /// The announcing half of the event bus, for the one flow whose view model
    /// does not announce its own result — see `LoginView.biometricSection`.
    var eventPublisher: any EventPublishing { get }
}
