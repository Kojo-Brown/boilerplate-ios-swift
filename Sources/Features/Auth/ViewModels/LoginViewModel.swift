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
    // `NSLock` rather than `Mutex`: the package deployment target is iOS 17 and
    // `Synchronization.Mutex` needs iOS 18. `EventBus` guards its state the same way.
    private let lock = NSLock()
    private var _shouldSucceed = true
    private var _delay: Duration = .milliseconds(100)

    var shouldSucceed: Bool {
        get { lock.withLock { _shouldSucceed } }
        set { lock.withLock { _shouldSucceed = newValue } }
    }

    var delay: Duration {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
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
