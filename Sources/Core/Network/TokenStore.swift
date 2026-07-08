import Foundation

// MARK: - Token pair

struct TokenPair: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
}

// MARK: - Refresh request body

struct TokenRefreshRequest: Encodable, Sendable {
    let refreshToken: String
}

// MARK: - Token store

/// Actor-isolated in-memory token store.
///
/// Concurrent 401 responses are coalesced: the first caller that notices the
/// token is stale triggers a refresh Task; all other callers await that same
/// Task instead of firing duplicate refresh requests.
///
/// Phase 3 will replace the in-memory store with Keychain persistence.
actor TokenStore {
    static let shared = TokenStore()

    private(set) var accessToken: String?
    private(set) var refreshToken: String?
    private var inflightRefresh: Task<String, Error>?

    func setTokens(_ pair: TokenPair) {
        accessToken = pair.accessToken
        refreshToken = pair.refreshToken
        inflightRefresh = nil
    }

    func clearTokens() {
        accessToken = nil
        refreshToken = nil
        inflightRefresh?.cancel()
        inflightRefresh = nil
    }

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
        // Coalesce concurrent refresh attempts.
        if let existing = inflightRefresh {
            return try await existing.value
        }

        guard let rt = refreshToken else { throw APIError.unauthorized }

        let task = Task { [weak self] () throws -> String in
            guard let self else { throw APIError.tokenRefreshFailed }
            let pair = try await performer(rt)
            await self.setTokens(pair)
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
