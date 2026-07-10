import AuthenticationServices
import GoogleSignInSwift
import SwiftUI
import UIKit

/// Login screen with email/password and social sign-in options.
/// Backed by `LoginViewModel` (email/password) and `SocialLoginViewModel` (Apple + Google).
struct LoginView: View {
    @State private var viewModel = LoginViewModel()
    @State private var socialViewModel = SocialLoginViewModel()
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    fields
                    if let message = viewModel.errorMessage ?? socialViewModel.errorMessage {
                        errorBanner(message)
                    }
                    loginButton
                    divider
                    socialButtons
                }
                .padding()
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.large)
            .onChange(of: viewModel.isAuthenticated) { _, authenticated in
                if authenticated { appState.isAuthenticated = true }
            }
            .onChange(of: socialViewModel.isAuthenticated) { _, authenticated in
                if authenticated { appState.isAuthenticated = true }
            }
        }
    }

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
    LoginView()
        .environment(AppState())
}
