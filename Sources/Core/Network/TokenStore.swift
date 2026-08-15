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

// MARK: - Protocol

/// The token lifecycle, as the network layer needs it.
///
/// This exists because `docs/solid.md` finding 2 recorded that it did not:
/// `URLSessionAPIClient`, `LiveAuthService` and `LiveSocialAuthExchangeService`
/// each stored `private let tokenStore: TokenStore` — the actor itself. That is
/// substitutable in principle, because the actor takes an injectable
/// `any KeychainStoring`, but the seam sits one level below the one a caller
/// wants: a test that needs "a store that reports the token as expired" had to
/// build a fake Keychain and populate it rather than pass a fake store, and
/// `refreshIfNeeded(using:)` — the most subtle code in the networking layer —
/// could only be substituted by not using it.
///
/// Four requirements, which is every member `TokenStore` has that anything
/// outside it calls. `accessToken` and `refreshToken` are deliberately absent:
/// they are read by the actor's own methods and by nothing else, so putting
/// them here would widen the contract past its only clients.
///
/// Every requirement is `async` because the live conformer is an actor. A
/// synchronous, non-throwing method on an actor witnesses an `async throws`
/// requirement fine; the reverse — a synchronous requirement — would force the
/// witness to be `nonisolated`, which is the opposite of what this type is for.
protocol TokenStoring: Sendable {
    /// Returns the stored access token, or throws when there is none.
    func currentToken() async throws -> String

    /// Persists a freshly issued pair, replacing whatever was held.
    func setTokens(_ pair: TokenPair) async throws

    /// Discards both tokens and abandons any refresh in flight.
    func clearTokens() async

    /// Returns a valid access token, triggering at most one refresh.
    ///
    /// - Parameter performer: Receives the stored refresh token and must return
    ///   a fresh `TokenPair` from the network.
    func refreshIfNeeded(
        using performer: @Sendable @escaping (String) async throws -> TokenPair
    ) async throws -> String
}

// MARK: - Token store

/// Actor-isolated, Keychain-backed token store.
///
/// Tokens are persisted to Keychain on every `setTokens` call so they survive
/// app restarts. Concurrent 401 responses are coalesced: the first caller that
/// notices the token is stale triggers a refresh Task; all other callers await
/// that same Task instead of firing duplicate refresh requests.
///
/// There is no `.shared` singleton any more. `AppContainer.live()` builds one
/// of these and hands the same instance to every collaborator that needs it —
/// see `docs/dependency-injection.md` for why a static was the wrong place for
/// that decision.
actor TokenStore: TokenStoring {
    private let keychain: any KeychainStoring
    private var inflightRefresh: Task<String, Error>?

    private enum Keys {
        static let accessToken = "com.boilerplate.accessToken"
        static let refreshToken = "com.boilerplate.refreshToken"
    }

    /// No default. The Keychain is a collaborator, and which one is used is a
    /// decision for the composition root rather than for whoever happens to
    /// build a store without saying.
    init(keychain: any KeychainStoring) {
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

        guard let storedRefreshToken = refreshToken else { throw APIError.unauthorized }

        let task = Task { [weak self] () async throws -> String in
            guard let self else { throw APIError.tokenRefreshFailed }
            let pair = try await performer(storedRefreshToken)
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

// MARK: - Double for previews & tests

/// In-memory `TokenStoring` with no Keychain behind it.
///
/// An `actor`, like the live type, on purpose. `docs/solid.md` finding 5 is a
/// double whose isolation differs from its live implementation, so that a test
/// using it can never observe a concurrency problem the real one would have;
/// making this a locked `final class` would have introduced exactly that split
/// into a brand-new abstraction.
///
/// **It does not coalesce.** `TokenStore.refreshIfNeeded(using:)` funnels
/// concurrent callers into one `Task`; this calls `performer` once per call.
/// That is a deliberate divergence and it is recorded rather than hidden: the
/// coalescing is the behaviour worth testing against the real store, and a
/// double that reimplements it would be a second, unreviewed copy of the
/// subtlest code in the networking layer. `refreshCount` is here so a test that
/// cares can assert on the call count itself.
actor InMemoryTokenStore: TokenStoring {
    private var pair: TokenPair?

    /// How many times `refreshIfNeeded(using:)` has run its performer.
    private(set) var refreshCount = 0

    init(pair: TokenPair? = nil) {
        self.pair = pair
    }

    func currentToken() throws -> String {
        guard let pair = pair else { throw APIError.unauthorized }
        return pair.accessToken
    }

    func setTokens(_ pair: TokenPair) {
        self.pair = pair
    }

    func clearTokens() {
        pair = nil
    }

    func refreshIfNeeded(
        using performer: @Sendable @escaping (String) async throws -> TokenPair
    ) async throws -> String {
        guard let refreshToken = pair?.refreshToken else { throw APIError.unauthorized }
        refreshCount += 1
        do {
            let fresh = try await performer(refreshToken)
            pair = fresh
            return fresh.accessToken
        } catch {
            pair = nil
            throw APIError.tokenRefreshFailed
        }
    }
}
