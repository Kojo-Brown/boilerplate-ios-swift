import Core
import Foundation
import Networking
import Observation
import os

/// Manages state and business logic for the login screen.
@Observable
@MainActor
package final class LoginViewModel: ViewModelProtocol {
    package var email = ""
    package var password = ""
    package var isLoading = false
    package var errorMessage: String?
    package var isAuthenticated = false

    // Computed validation — automatically re-evaluated by Observation
    package var isFormValid: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty
            && password.count >= 8
            && email.contains("@")
    }

    private let authService: any AuthServiceProtocol
    private let events: any EventPublishing

    /// Built by `AppContainer.makeLoginViewModel()`. There is no default: a
    /// view model that can name its own live collaborator is a second
    /// composition root, and this package now has one.
    package init(authService: any AuthServiceProtocol, events: any EventPublishing) {
        self.authService = authService
        self.events = events
    }

    package func login() async {
        guard isFormValid else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let succeeded = try await authService.login(email: email, password: password)
            isAuthenticated = succeeded

            // `isAuthenticated` says what happened on *this screen*; the event
            // says what happened to the app. `LoginView` used to bridge the two
            // with an `.onChange` that assigned `appState.isAuthenticated`,
            // which made the screen responsible for every consequence of a
            // sign-in and left `currentUserEmail` unset because that one did not
            // occur to it. Announcing instead leaves the consequences to
            // `SessionObserver`.
            //
            // The address published is the one the request was made with,
            // untrimmed, so the event says what was authenticated rather than a
            // tidied version of it. The response's `User` would be the better
            // source and is unreachable: `AuthServiceProtocol.login` returns
            // `Bool`, discarding the `LoginResponse.user` that `LiveAuthService`
            // already has in hand. Widening that contract is its own change.
            if succeeded {
                events.publish(UserSignedIn(method: .password, email: email))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    package func clearError() {
        errorMessage = nil
    }
}

// MARK: - Auth Service Protocol

package protocol AuthServiceProtocol: Sendable {
    func login(email: String, password: String) async throws -> Bool
}

// MARK: - Live implementation

package struct LiveAuthService: AuthServiceProtocol {
    private let client: any APIClient
    private let tokenStore: any TokenStoring

    package init(client: any APIClient, tokenStore: any TokenStoring) {
        self.client = client
        self.tokenStore = tokenStore
    }

    package func login(email: String, password: String) async throws -> Bool {
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
package final class MockAuthService: AuthServiceProtocol {
    package init() {}

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

    package var shouldSucceed: Bool {
        get { state.withLock { $0.shouldSucceed } }
        set { state.withLock { $0.shouldSucceed = newValue } }
    }

    package var delay: Duration {
        get { state.withLock { $0.delay } }
        set { state.withLock { $0.delay = newValue } }
    }

    package func login(email _: String, password _: String) async throws -> Bool {
        try await Task.sleep(for: delay)
        guard shouldSucceed else { throw AuthError.invalidCredentials }
        return true
    }
}

package enum AuthError: LocalizedError {
    case invalidCredentials
    case networkUnavailable

    package var errorDescription: String? {
        switch self {
        case .invalidCredentials: "Invalid email or password."
        case .networkUnavailable: "No network connection."
        }
    }
}
