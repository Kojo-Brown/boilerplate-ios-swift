import AuthenticationServices
import Core
import GoogleSignInSwift
import SwiftUI
import UIKit

/// Login screen with email/password, social sign-in, and biometric options.
/// Backed by `LoginViewModel`, `SocialLoginViewModel`, and `BiometricAuthViewModel`.
package struct LoginView: View {
    @State private var viewModel: LoginViewModel
    @State private var socialViewModel: SocialLoginViewModel
    @State private var biometricViewModel: BiometricAuthViewModel

    /// The announcing half of the event bus, for the one flow whose view model
    /// does not announce its own result — see `biometricSection`.
    private let events: any EventPublishing

    /// Where VoiceOver is sent when a sign-in attempt fails.
    ///
    /// A banner that appears below the fields is, to a reader who is still
    /// focused on the password field, nothing at all: SwiftUI does not move
    /// focus for a view that was inserted, and the attempt simply seems not to
    /// have happened. Moving focus onto the banner is what turns the failure
    /// into something that is said out loud, and it is also why the banner is
    /// `.isStaticText` rather than a button — landing on it must not imply
    /// that activating it retries anything.
    @AccessibilityFocusState private var errorIsFocused: Bool

    /// The three view models this screen owns are built by whoever supplies
    /// `LoginDependencies` — the composition root in the app, this feature's own
    /// double in a preview — so the view never names an auth service, an
    /// identity provider or a token store.
    ///
    /// `State(wrappedValue:)` rather than a stored default: SwiftUI keeps the
    /// value produced by the first initialisation and discards the rest, so a
    /// re-init from a parent body evaluation costs three allocations and does
    /// not reset the screen's state.
    @MainActor
    package init(dependencies: any LoginDependencies) {
        _viewModel = State(wrappedValue: dependencies.makeLoginViewModel())
        _socialViewModel = State(wrappedValue: dependencies.makeSocialLoginViewModel())
        _biometricViewModel = State(wrappedValue: dependencies.makeBiometricAuthViewModel())
        events = dependencies.eventPublisher
    }

    package var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    fields
                    if let message = errorMessage {
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
            .onChange(of: errorMessage) { _, message in
                errorIsFocused = message != nil
            }
        }
    }

    /// The one message this screen shows, whoever produced it.
    ///
    /// Three flows can fail and only one banner is ever on screen, so the
    /// precedence is a property rather than a chain of `??` inside the body —
    /// which is also what makes it something `.onChange` can watch.
    private var errorMessage: String? {
        viewModel.errorMessage
            ?? socialViewModel.errorMessage
            ?? biometricViewModel.errorMessage
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
            // Decoration, and deliberately fixed at 56 points rather than
            // scaled: it carries no information the title below does not, so
            // it is hidden from VoiceOver, and a hero glyph that tripled in
            // height at `AX5` would push the form it introduces off the screen.
            // What scales here is the type.
            Image(systemName: "swift")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            // A heading, which is what puts it on VoiceOver's heading rotor.
            // The navigation title is already one; this is the other, and
            // between them a reader can skip the form rather than swiping
            // through it. See `docs/accessibility.md`.
            Text("Boilerplate iOS")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// The placeholders stay as they are — they are the only prompt a sighted
    /// reader gets once a field has focus. What changes is that the rule buried
    /// in one of them ("8+ chars") becomes a hint rather than part of the
    /// field's name: a label answers "what is this", a hint answers "what is
    /// expected of me", and a control whose *name* changes when its rules do is
    /// a control VoiceOver cannot be told to find again.
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
                .accessibilityLabel("Email")

            SecureField("Password (8+ chars)", text: $viewModel.password)
                .textContentType(.password)
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Password")
                .accessibilityHint("At least 8 characters")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        InlineErrorBanner(message, onDismiss: clearErrors)
            .accessibilityFocused($errorIsFocused)
    }

    /// One closure for both ways of dismissing the banner, so the tap gesture
    /// and the VoiceOver action cannot clear different things.
    private func clearErrors() {
        viewModel.clearError()
        socialViewModel.clearError()
        biometricViewModel.clearError()
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
                        .accessibilityHidden(true)
                } else {
                    Text("Sign In")
                        .font(.body.bold())
                }
            }
            .frame(maxWidth: .infinity)
            .scaledControlHeight()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!viewModel.isFormValid || viewModel.isLoading || socialViewModel.isLoading)
        .animation(.default, value: viewModel.isLoading)
        // Without this the button is genuinely nameless while the request is in
        // flight: the branch that holds the word "Sign In" is not in the tree,
        // and the one that replaces it is a spinner.
        .accessibilityLabel("Sign In")
        .accessibilityBusy(viewModel.isLoading, doing: "Signing in")
    }

    /// Two rules and the word between them. The rules are drawing; the word is
    /// what the drawing means, so the whole thing is one element saying it.
    /// Left alone it is a bare "or" in the middle of the form, which is the
    /// same information with none of the shape that made it legible.
    private var divider: some View {
        HStack {
            Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1)
            Text("or").font(.footnote).foregroundStyle(.secondary)
            Rectangle().fill(.secondary.opacity(0.3)).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("or, sign in another way")
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
            // The dimming and the spinner are the in-flight state drawn. The
            // spinner is hidden because it would sit in front of Apple's own
            // button as a second, nameless element; what it was there to say is
            // said as the button's value instead.
            .overlay {
                if socialViewModel.isLoadingApple {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.black.opacity(0.5))
                    ProgressView()
                        .tint(.white)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityBusy(socialViewModel.isLoadingApple, doing: "Signing in")

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
    LoginView(dependencies: PreviewLoginDependencies())
}
