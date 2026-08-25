import AuthenticationServices
import Core
import Foundation
import Networking
import os

// MARK: - Protocols

/// Abstracts a single social identity provider (Apple or Google).
package protocol SocialAuthProvider: Sendable {
    func signIn(anchor: ASPresentationAnchor) async throws -> SocialAuthCredential
}

/// Exchanges a raw social credential for app-issued JWT tokens.
package protocol SocialAuthExchangeService: Sendable {
    func exchange(_ credential: SocialAuthCredential) async throws -> LoginResponse
}

// MARK: - Live exchange implementation

package struct LiveSocialAuthExchangeService: SocialAuthExchangeService {
    private let client: any APIClient
    private let tokenStore: any TokenStoring

    package init(client: any APIClient, tokenStore: any TokenStoring) {
        self.client = client
        self.tokenStore = tokenStore
    }

    package func exchange(_ credential: SocialAuthCredential) async throws -> LoginResponse {
        let body = SocialLoginRequest(credential: credential)
        let endpoint = try APIEndpoint.post("/auth/social", body: body, requiresAuth: false)
        let response: LoginResponse = try await client.send(endpoint)
        try await tokenStore.setTokens(
            TokenPair(accessToken: response.accessToken, refreshToken: response.refreshToken)
        )
        return response
    }
}

private extension SocialLoginRequest {
    init(credential: SocialAuthCredential) {
        switch credential {
        case let .apple(identityToken, authorizationCode, nonce, fullName):
            self = SocialLoginRequest(
                provider: "apple",
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                nonce: nonce,
                givenName: fullName?.givenName,
                familyName: fullName?.familyName
            )
        case let .google(idToken, _):
            self = SocialLoginRequest(
                provider: "google",
                identityToken: idToken,
                authorizationCode: nil,
                nonce: nil,
                givenName: nil,
                familyName: nil
            )
        }
    }
}

// MARK: - Mocks for tests and previews

/// Both protocols are `Sendable`, so these doubles keep their knobs behind a
/// lock rather than under `@unchecked Sendable`. `shouldThrow` is
/// `any Error & Sendable` rather than `any Error` for the same reason the
/// text-recognition and barcode doubles already use that spelling: the bare
/// existential is not `Sendable`, so storing one would sink the conformance.
package final class MockSocialAuthProvider: SocialAuthProvider {
    package init() {}

    private struct State: Sendable {
        var credential: SocialAuthCredential = .apple(
            identityToken: "mock_id_token",
            authorizationCode: "mock_auth_code",
            nonce: "mock_nonce",
            fullName: nil
        )
        var shouldThrow: (any Error & Sendable)?
        var delay: Duration = .milliseconds(50)
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package var credential: SocialAuthCredential {
        get { state.withLock { $0.credential } }
        set { state.withLock { $0.credential = newValue } }
    }

    package var shouldThrow: (any Error & Sendable)? {
        get { state.withLock { $0.shouldThrow } }
        set { state.withLock { $0.shouldThrow = newValue } }
    }

    package var delay: Duration {
        get { state.withLock { $0.delay } }
        set { state.withLock { $0.delay = newValue } }
    }

    package func signIn(anchor _: ASPresentationAnchor) async throws -> SocialAuthCredential {
        // One snapshot up front, so the sleep is not a window in which the
        // configuration can change under the call that is already running.
        let snapshot = state.withLock { $0 }
        try await Task.sleep(for: snapshot.delay)
        if let error = snapshot.shouldThrow { throw error }
        return snapshot.credential
    }
}

package final class MockSocialAuthExchangeService: SocialAuthExchangeService {
    package init() {}

    private struct State: Sendable {
        var response = LoginResponse(
            accessToken: "mock_access_token",
            refreshToken: "mock_refresh_token",
            user: User(email: "social@example.com", name: "Social User")
        )
        var shouldThrow: (any Error & Sendable)?
        var delay: Duration = .milliseconds(50)
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package var response: LoginResponse {
        get { state.withLock { $0.response } }
        set { state.withLock { $0.response = newValue } }
    }

    package var shouldThrow: (any Error & Sendable)? {
        get { state.withLock { $0.shouldThrow } }
        set { state.withLock { $0.shouldThrow = newValue } }
    }

    package var delay: Duration {
        get { state.withLock { $0.delay } }
        set { state.withLock { $0.delay = newValue } }
    }

    package func exchange(_: SocialAuthCredential) async throws -> LoginResponse {
        let snapshot = state.withLock { $0 }
        try await Task.sleep(for: snapshot.delay)
        if let error = snapshot.shouldThrow { throw error }
        return snapshot.response
    }
}
