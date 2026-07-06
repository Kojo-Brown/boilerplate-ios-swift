import SwiftUI

/// Login screen backed by `LoginViewModel` via the Observation framework.
/// `@State` is correct here — Observation tracks individual property access
/// rather than requiring `@StateObject`/`@ObservedObject`.
struct LoginView: View {
    @State private var viewModel = LoginViewModel()
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                header
                fields
                if let message = viewModel.errorMessage {
                    errorBanner(message)
                }
                loginButton
            }
            .padding()
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.large)
            .onChange(of: viewModel.isAuthenticated) { _, authenticated in
                if authenticated {
                    appState.isAuthenticated = true
                }
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
        .onTapGesture { viewModel.clearError() }
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
        .disabled(!viewModel.isFormValid || viewModel.isLoading)
        .animation(.default, value: viewModel.isLoading)
    }
}

// MARK: - Preview

#Preview {
    LoginView()
        .environment(AppState())
}
