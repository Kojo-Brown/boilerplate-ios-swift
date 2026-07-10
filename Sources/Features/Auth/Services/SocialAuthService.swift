import AuthenticationServices
import Foundation

// MARK: - Protocols

/// Abstracts a single social identity provider (Apple or Google).
protocol SocialAuthProvider: Sendable {
    func signIn(anchor: ASPresentationAnchor) async throws -> SocialAuthCredential
}

/// Exchanges a raw social credential for app-issued JWT tokens.
protocol SocialAuthExchangeService: Sendable {
    func exchange(_ credential: SocialAuthCredential) async throws -> LoginResponse
}

// MARK: - Live exchange implementation

struct LiveSocialAuthExchangeService: SocialAuthExchangeService {
    private let client: any APIClient
    private let tokenStore: TokenStore

    init(
        client: any APIClient = URLSessionAPIClient.shared,
        tokenStore: TokenStore = .shared
    ) {
        self.client = client
        self.tokenStore = tokenStore
    }

    func exchange(_ credential: SocialAuthCredential) async throws -> LoginResponse {
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

final class MockSocialAuthProvider: SocialAuthProvider, @unchecked Sendable {
    var credential: SocialAuthCredential = .apple(
        identityToken: "mock_id_token",
        authorizationCode: "mock_auth_code",
        nonce: "mock_nonce",
        fullName: nil
    )
    var shouldThrow: Error?
    var delay: Duration = .milliseconds(50)

    func signIn(anchor: ASPresentationAnchor) async throws -> SocialAuthCredential {
        try await Task.sleep(for: delay)
        if let error = shouldThrow { throw error }
        return credential
    }
}

final class MockSocialAuthExchangeService: SocialAuthExchangeService, @unchecked Sendable {
    var response: LoginResponse = LoginResponse(
        accessToken: "mock_access_token",
        refreshToken: "mock_refresh_token",
        user: User(email: "social@example.com", name: "Social User")
    )
    var shouldThrow: Error?
    var delay: Duration = .milliseconds(50)

    func exchange(_ credential: SocialAuthCredential) async throws -> LoginResponse {
        try await Task.sleep(for: delay)
        if let error = shouldThrow { throw error }
        return response
    }
}
