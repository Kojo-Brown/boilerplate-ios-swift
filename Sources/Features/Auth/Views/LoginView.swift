import AuthenticationServices
import GoogleSignInSwift
import SwiftUI
import UIKit

/// Login screen with email/password, social sign-in, and biometric options.
/// Backed by `LoginViewModel`, `SocialLoginViewModel`, and `BiometricAuthViewModel`.
struct LoginView: View {
    @State private var viewModel: LoginViewModel
    @State private var socialViewModel: SocialLoginViewModel
    @State private var biometricViewModel: BiometricAuthViewModel

    /// The announcing half of the event bus, for the one flow whose view model
    /// does not announce its own result — see `biometricSection`.
    private let events: any EventPublishing

    /// The three view models this screen owns come from the container, so the
    /// view never names an auth service, an identity provider or a token store.
    ///
    /// `State(wrappedValue:)` rather than a stored default: SwiftUI keeps the
    /// value produced by the first initialisation and discards the rest, so a
    /// re-init from a parent body evaluation costs three allocations and does
    /// not reset the screen's state.
    @MainActor
    init(container: AppContainer) {
        _viewModel = State(wrappedValue: container.makeLoginViewModel())
        _socialViewModel = State(wrappedValue: container.makeSocialLoginViewModel())
        _biometricViewModel = State(wrappedValue: container.makeBiometricAuthViewModel())
        events = container.eventPublisher
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    fields
                    if let message = viewModel.errorMessage
                        ?? socialViewModel.errorMessage
                        ?? biometricViewModel.errorMessage {
                        errorBanner(message)
                    }
                    loginButton
                    divider
                    socialButtons
                    if biometricViewModel.isAvailable {
                        biometricSection
                    }
                }
                .padding()
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // Three `.onChange` blocks used to sit here, one per sign-in flow, each
    // copying a view model's `isAuthenticated` into `AppState`'s — and the
    // biometric one duplicated the button callback below, which did the same
    // assignment on the same success. That is the observer pattern written by
    // hand at the call site: this screen watched three flags and was, by being
    // the watcher, the only thing that could act on them. It acted on one
    // consequence and missed two, both of which `SessionObserver` now carries.
    // The screen no longer reads `AppState` at all.

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "swift")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Boilerplate iOS")
                .font(.title2.bold())
        }
    }

    private var fields: some View {
        VStack(spacing: 16) {
            TextField("Email", text: $viewModel.email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            SecureField("Password (8+ chars)", text: $viewModel.password)
                .textContentType(.password)
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.subheadline)
        }
        .foregroundStyle(.red)
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            viewModel.clearError()
            socialViewModel.clearError()
            biometricViewModel.clearError()
        }
    }

    private var loginButton: some View {
        Button {
            Task { await viewModel.login() }
        } label: {
            Group {
                if viewModel.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Text("Sign In")
                        .font(.body.bold())
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!viewModel.isFormValid || viewModel.isLoading || socialViewModel.isLoading)
        .animation(.default, value: viewModel.isLoading)
    }

    private var divider: some View {
        HStack {
            Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1)
            Text("or").font(.footnote).foregroundStyle(.secondary)
            Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1)
        }
    }

    private var biometricSection: some View {
        BiometricAuthButton(viewModel: biometricViewModel) {
            // The one flow that announces from the screen rather than from its
            // view model. A successful evaluation means "this is the device's
            // owner", and what that *implies* depends on who asked:
            // `BiometricAuthButton` is also used on its own to re-authenticate
            // somebody already signed in, where `UserSignedIn` would be a lie.
            // Here it means a session began, so here is where it is said — with
            // no email, because the evaluation returns a yes and not an identity.
            events.publish(UserSignedIn(method: .biometric, email: nil))
        }
        .disabled(viewModel.isLoading || socialViewModel.isLoading)
    }

    private var socialButtons: some View {
        VStack(spacing: 12) {
            SignInWithAppleButton(.signIn) { request in
                socialViewModel.prepareAppleNonce()
                request.requestedScopes = [.fullName, .email]
                request.nonce = socialViewModel.appleNonceHash
            } onCompletion: { result in
                Task { await socialViewModel.handleAppleResult(result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(socialViewModel.isLoading || viewModel.isLoading)
            .overlay {
                if socialViewModel.isLoadingApple {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.black.opacity(0.5))
                    ProgressView().tint(.white)
                }
            }

            GoogleSignInButton(scheme: .dark, style: .wide, state: .normal) {
                Task {
                    guard let window = keyWindow else { return }
                    await socialViewModel.signInWithGoogle(anchor: window)
                }
            }
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .disabled(socialViewModel.isLoading || viewModel.isLoading)
        }
    }

    // MARK: - Helpers

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}

// MARK: - Preview

#Preview {
    LoginView(container: .preview)
}
