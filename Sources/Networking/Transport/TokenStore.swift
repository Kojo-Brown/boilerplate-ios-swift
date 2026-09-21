import Core
import Foundation

// MARK: - Token pair

package struct TokenPair: Codable, Sendable {
    package let accessToken: String
    package let refreshToken: String

    package init(accessToken: String, refreshToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    package enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

// MARK: - Refresh request body

package struct TokenRefreshRequest: Encodable, Sendable {
    package let refreshToken: String

    package enum CodingKeys: String, CodingKey {
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
package protocol TokenStoring: Sendable {
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

// MARK: - Biometric unlock policy

/// Whether the store keeps a copy of the refresh token behind an
/// authentication gate, and what that gate is.
///
/// The session tokens themselves are never gated — see `TokenStore` — so this
/// is the whole of the app's biometric protection, and it is the composition
/// root's decision rather than the store's: `AppContainer.live()` turns it on,
/// `AppContainer.preview` leaves it off.
package enum BiometricUnlockPolicy: Sendable, Equatable {
    case disabled
    case enabled(KeychainAccessPolicy)

    /// What the app ships with: the enrolled biometric set as it stood when
    /// the record was written, with the device passcode as the way back in.
    /// `KeychainAccessPolicy.biometryCurrentSetOrPasscode` says why.
    package static let deviceOwner = BiometricUnlockPolicy.enabled(.biometryCurrentSetOrPasscode)

    /// The policy the record is written under, or `nil` when there is no
    /// record to write.
    ///
    /// `.enabled(.afterFirstUnlockThisDeviceOnly)` reads as disabled rather
    /// than as an unlock record that unlocks nothing. A second copy of the
    /// refresh token is only worth its own key while it is harder to reach
    /// than the first one; an ungated copy is strictly a second thing to
    /// steal.
    package var gatedPolicy: KeychainAccessPolicy? {
        switch self {
        case .disabled:
            nil
        case .enabled(let policy):
            policy.requiresAuthentication ? policy : nil
        }
    }
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
package actor TokenStore: TokenStoring {
    private let keychain: any KeychainStoring
    private let biometricUnlock: BiometricUnlockPolicy
    private var inflightRefresh: Task<String, Error>?

    /// The three account names this store owns, exposed so that a test — and
    /// `Tools/assert-token-storage.py` — can name the same strings the store
    /// writes rather than a copy of them that drifts.
    package enum Keys {
        package static let accessToken = "com.boilerplate.accessToken"
        package static let refreshToken = "com.boilerplate.refreshToken"

        /// The gated copy. A separate key rather than a stronger policy on
        /// `refreshToken`, because the two are read by different callers under
        /// different conditions and one item cannot be both.
        package static let biometricRefreshToken = "com.boilerplate.biometricRefreshToken"
    }

    /// What the session tokens are written under, and why it is not a gate.
    ///
    /// Both tokens are read by machinery with nobody in front of it: the
    /// retry after a 401, and the background refresh task that runs while the
    /// phone is in a pocket. `afterFirstUnlockThisDeviceOnly` is the strongest
    /// accessibility that survives both — the device is locked, so
    /// `whenUnlocked` would fail, and any authentication constraint would put
    /// a prompt on a screen nobody is looking at (or, before
    /// `KeychainWrapper` started attaching a non-interactive context, hang
    /// waiting for one). It never leaves the device and never enters a backup.
    ///
    /// The biometric gating the app does have is the unlock record below.
    package static let sessionPolicy = KeychainAccessPolicy.afterFirstUnlockThisDeviceOnly

    /// Why the last attempt to write the unlock record did not happen, or
    /// `nil` when it did.
    ///
    /// Recorded rather than thrown. A device with no passcode cannot hold a
    /// gated item at all, and failing `setTokens` there would mean a
    /// successful sign-in that the app then reports as a failure — the
    /// opposite of the trade the record exists to make. The failure is still
    /// legible: this is what a caller reads to find out that "unlock with Face
    /// ID" is not going to be offered, and why.
    package private(set) var lastBiometricUnlockError: KeychainError?

    /// No default for `keychain`. The Keychain is a collaborator, and which
    /// one is used is a decision for the composition root rather than for
    /// whoever happens to build a store without saying.
    ///
    /// `biometricUnlock` does default, and the default is the absence of the
    /// feature. It is a policy value rather than a collaborator, and every
    /// call site that does not name one wants the store it has always had.
    package init(
        keychain: any KeychainStoring,
        biometricUnlock: BiometricUnlockPolicy = .disabled
    ) {
        self.keychain = keychain
        self.biometricUnlock = biometricUnlock
    }

    // MARK: - Token access

    package var accessToken: String? {
        try? keychain.string(forKey: Keys.accessToken)
    }

    package var refreshToken: String? {
        try? keychain.string(forKey: Keys.refreshToken)
    }

    // MARK: - Mutations

    package func setTokens(_ pair: TokenPair) throws {
        try keychain.set(pair.accessToken, forKey: Keys.accessToken, policy: Self.sessionPolicy)
        try keychain.set(pair.refreshToken, forKey: Keys.refreshToken, policy: Self.sessionPolicy)
        // Every write, not only the first: a refresh rotates the token, and a
        // gated record still holding the previous one would authenticate the
        // user successfully and then fail the exchange.
        writeBiometricUnlockRecord(pair.refreshToken)
        inflightRefresh = nil
    }

    package func clearTokens() {
        try? keychain.remove(forKey: Keys.accessToken)
        try? keychain.remove(forKey: Keys.refreshToken)
        // Signing out has to take the gated copy with it. It is the one item
        // that would otherwise survive a sign-out and let the next person
        // holding the phone reach the account with a glance.
        try? keychain.remove(forKey: Keys.biometricRefreshToken)
        lastBiometricUnlockError = nil
        inflightRefresh?.cancel()
        inflightRefresh = nil
    }

    // MARK: - Biometric unlock

    /// Whether a gated record exists on this device. Does not prompt.
    ///
    /// The question a screen asks before offering "unlock with Face ID", and
    /// the reason `KeychainStoring` has a `contains`: asking by reading would
    /// mean prompting to find out whether to prompt.
    package var isBiometricUnlockEnrolled: Bool {
        (try? keychain.contains(Keys.biometricRefreshToken)) ?? false
    }

    /// Reads the gated refresh token, prompting for biometry or the passcode.
    ///
    /// - Parameter reason: Shown verbatim in the system prompt.
    /// - Returns: The refresh token, to be exchanged for a fresh pair.
    /// - Throws: `APIError.unauthorized` when this store keeps no gated record
    ///   or the device has none; `KeychainError.userCancelled` when the user
    ///   declines; `KeychainError.authenticationFailed` when they cannot
    ///   authenticate.
    ///
    /// The read happens off this actor. `SecItemCopyMatching` blocks its
    /// thread for as long as the sheet is up — user time, not machine time —
    /// and the store has other callers whose requests should not queue behind
    /// somebody looking at their phone.
    package func biometricRefreshToken(reason: String) async throws -> String {
        guard biometricUnlock.gatedPolicy != nil else { throw APIError.unauthorized }

        let keychain = self.keychain
        let key = Keys.biometricRefreshToken
        let stored = try await OffMainActor.run {
            try keychain.string(forKey: key, authenticationReason: reason)
        }
        guard let stored else { throw APIError.unauthorized }
        return stored
    }

    /// Removes the gated record, leaving the session intact.
    ///
    /// What a "stop using Face ID for this app" switch calls. Signing out
    /// removes it too, but the two are not the same request.
    package func disableBiometricUnlock() {
        try? keychain.remove(forKey: Keys.biometricRefreshToken)
        lastBiometricUnlockError = nil
    }

    private func writeBiometricUnlockRecord(_ refreshToken: String) {
        guard let policy = biometricUnlock.gatedPolicy else {
            // Turning the policy off has to clear what an earlier launch left
            // behind, or the record outlives the decision that created it.
            try? keychain.remove(forKey: Keys.biometricRefreshToken)
            lastBiometricUnlockError = nil
            return
        }

        do {
            try keychain.set(refreshToken, forKey: Keys.biometricRefreshToken, policy: policy)
            lastBiometricUnlockError = nil
        } catch {
            try? keychain.remove(forKey: Keys.biometricRefreshToken)
            lastBiometricUnlockError = KeychainError.wrapping(error)
        }
    }

    // MARK: - Auth helpers

    /// Returns the stored access token or throws `APIError.unauthorized`.
    package func currentToken() throws -> String {
        guard let token = accessToken else { throw APIError.unauthorized }
        return token
    }

    /// Returns a valid access token, triggering a single refresh when needed.
    ///
    /// - Parameter performer: Receives the stored refresh token and must
    ///   return a fresh `TokenPair` from the network. Called at most once even
    ///   when multiple callers race on a 401.
    package func refreshIfNeeded(
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
package actor InMemoryTokenStore: TokenStoring {
    private var pair: TokenPair?

    /// How many times `refreshIfNeeded(using:)` has run its performer.
    private(set) var refreshCount = 0

    package init(pair: TokenPair? = nil) {
        self.pair = pair
    }

    package func currentToken() throws -> String {
        guard let pair = pair else { throw APIError.unauthorized }
        return pair.accessToken
    }

    package func setTokens(_ pair: TokenPair) {
        self.pair = pair
    }

    package func clearTokens() {
        pair = nil
    }

    package func refreshIfNeeded(
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
