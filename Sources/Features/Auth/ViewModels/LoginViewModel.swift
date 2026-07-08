import Foundation
import Observation

/// Manages state and business logic for the login screen.
@Observable
@MainActor
final class LoginViewModel: ViewModelProtocol {
    var email = ""
    var password = ""
    var isLoading = false
    var errorMessage: String?
    var isAuthenticated = false

    // Computed validation — automatically re-evaluated by Observation
    var isFormValid: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty
            && password.count >= 8
            && email.contains("@")
    }

    private let authService: AuthServiceProtocol

    init(authService: AuthServiceProtocol = LiveAuthService()) {
        self.authService = authService
    }

    func login() async {
        guard isFormValid else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            isAuthenticated = try await authService.login(email: email, password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }
}

// MARK: - Auth Service Protocol

protocol AuthServiceProtocol: Sendable {
    func login(email: String, password: String) async throws -> Bool
}

// MARK: - Live implementation

struct LiveAuthService: AuthServiceProtocol {
    private let client: any APIClient
    private let tokenStore: TokenStore

    init(
        client: any APIClient = URLSessionAPIClient.shared,
        tokenStore: TokenStore = .shared
    ) {
        self.client = client
        self.tokenStore = tokenStore
    }

    func login(email: String, password: String) async throws -> Bool {
        let endpoint = try APIEndpoint.post(
            "/auth/login",
            body: LoginRequest(email: email, password: password),
            requiresAuth: false
        )
        let response: LoginResponse = try await client.send(endpoint)
        await tokenStore.setTokens(
            TokenPair(accessToken: response.accessToken, refreshToken: response.refreshToken)
        )
        return true
    }
}

// MARK: - Mock for previews & tests

final class MockAuthService: AuthServiceProtocol {
    var shouldSucceed = true
    var delay: Duration = .milliseconds(100)

    func login(email: String, password: String) async throws -> Bool {
        try await Task.sleep(for: delay)
        if shouldSucceed { return true }
        throw AuthError.invalidCredentials
    }
}

enum AuthError: LocalizedError {
    case invalidCredentials
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: "Invalid email or password."
        case .networkUnavailable: "No network connection."
        }
    }
}
