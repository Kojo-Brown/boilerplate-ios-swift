import Foundation
import Observation
import os

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

    private let authService: any AuthServiceProtocol

    /// Built by `AppContainer.makeLoginViewModel()`. There is no default: a
    /// view model that can name its own live collaborator is a second
    /// composition root, and this package now has one.
    init(authService: any AuthServiceProtocol) {
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
    private let tokenStore: any TokenStoring

    init(client: any APIClient, tokenStore: any TokenStoring) {
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
        try await tokenStore.setTokens(
            TokenPair(accessToken: response.accessToken, refreshToken: response.refreshToken)
        )
        return true
    }
}

// MARK: - Mock for previews & tests

/// `AuthServiceProtocol` is `Sendable`, so this double cannot hold bare mutable
/// state. The knobs live behind a lock rather than under `@unchecked Sendable`,
/// so a test that configures the mock from one task and exercises it from
/// another is actually safe instead of only asserted to be.
final class MockAuthService: AuthServiceProtocol {
    private struct State: Sendable {
        var shouldSucceed = true
        var delay: Duration = .milliseconds(100)
    }

    // The state lives *inside* the lock rather than beside it, so the class has no
    // mutable stored property for Swift 6 to reject — a plain `NSLock` next to
    // `private var` still trips the check, because the compiler cannot see that the
    // lock guards them. `OSAllocatedUnfairLock` is `Sendable` whenever its state is,
    // and is iOS 16+, so it fits this package's iOS 17 floor where
    // `Synchronization.Mutex` (iOS 18) would not.
    private let state = OSAllocatedUnfairLock(initialState: State())

    var shouldSucceed: Bool {
        get { state.withLock { $0.shouldSucceed } }
        set { state.withLock { $0.shouldSucceed = newValue } }
    }

    var delay: Duration {
        get { state.withLock { $0.delay } }
        set { state.withLock { $0.delay = newValue } }
    }

    func login(email _: String, password _: String) async throws -> Bool {
        try await Task.sleep(for: delay)
        guard shouldSucceed else { throw AuthError.invalidCredentials }
        return true
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
