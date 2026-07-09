import Foundation

// MARK: - Token pair

struct TokenPair: Codable, Sendable {
    let accessToken: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

// MARK: - Refresh request body

struct TokenRefreshRequest: Encodable, Sendable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

// MARK: - Token store

/// Actor-isolated, Keychain-backed token store.
///
/// Tokens are persisted to Keychain on every `setTokens` call so they survive
/// app restarts. Concurrent 401 responses are coalesced: the first caller that
/// notices the token is stale triggers a refresh Task; all other callers await
/// that same Task instead of firing duplicate refresh requests.
actor TokenStore {
    static let shared = TokenStore()

    private let keychain: any KeychainStoring
    private var inflightRefresh: Task<String, Error>?

    private enum Keys {
        static let accessToken = "com.boilerplate.accessToken"
        static let refreshToken = "com.boilerplate.refreshToken"
    }

    init(keychain: any KeychainStoring = KeychainWrapper()) {
        self.keychain = keychain
    }

    // MARK: - Token access

    var accessToken: String? {
        try? keychain.string(forKey: Keys.accessToken)
    }

    var refreshToken: String? {
        try? keychain.string(forKey: Keys.refreshToken)
    }

    // MARK: - Mutations

    func setTokens(_ pair: TokenPair) throws {
        try keychain.set(pair.accessToken, forKey: Keys.accessToken)
        try keychain.set(pair.refreshToken, forKey: Keys.refreshToken)
        inflightRefresh = nil
    }

    func clearTokens() {
        try? keychain.remove(forKey: Keys.accessToken)
        try? keychain.remove(forKey: Keys.refreshToken)
        inflightRefresh?.cancel()
        inflightRefresh = nil
    }

    // MARK: - Auth helpers

    /// Returns the stored access token or throws `APIError.unauthorized`.
    func currentToken() throws -> String {
        guard let token = accessToken else { throw APIError.unauthorized }
        return token
    }

    /// Returns a valid access token, triggering a single refresh when needed.
    ///
    /// - Parameter performer: Receives the stored refresh token and must
    ///   return a fresh `TokenPair` from the network. Called at most once even
    ///   when multiple callers race on a 401.
    func refreshIfNeeded(
        using performer: @Sendable @escaping (String) async throws -> TokenPair
    ) async throws -> String {
        if let existing = inflightRefresh {
            return try await existing.value
        }

        guard let rt = refreshToken else { throw APIError.unauthorized }

        let task = Task { [weak self] () throws -> String in
            guard let self else { throw APIError.tokenRefreshFailed }
            let pair = try await performer(rt)
            try await self.setTokens(pair)
            return pair.accessToken
        }
        inflightRefresh = task

        do {
            let token = try await task.value
            inflightRefresh = nil
            return token
        } catch {
            clearTokens()
            inflightRefresh = nil
            throw APIError.tokenRefreshFailed
        }
    }
}
