import Core
import Foundation
import os

// MARK: - The challenge

/// A one-time value the server issues and the client signs.
///
/// It is the only thing standing between an assertion and a replay. App Attest's
/// counter narrows the window — a server that tracks it refuses any assertion
/// whose counter it has already seen — but the counter is per key and says
/// nothing about *when* the assertion was made, so a challenge is what lets the
/// server bound the age of one it accepts.
///
/// `expiresAt` is advisory on this side. The client uses it to avoid signing a
/// challenge it already knows is stale, which turns a guaranteed rejection into
/// a second fetch; the decision that matters is the server's, because a client
/// that could decide its own challenge was fresh could decide anything.
package struct AttestationChallenge: Hashable, Sendable, Codable {

    /// The challenge, verbatim, exactly as it goes into the client data and the
    /// `X-Attest-Challenge` header. Opaque: this app never parses it.
    package let value: String

    /// When the server says it stops accepting this challenge, when it says.
    package let expiresAt: Date?

    package init(value: String, expiresAt: Date? = nil) {
        self.value = value
        self.expiresAt = expiresAt
    }

    package enum CodingKeys: String, CodingKey {
        case value = "challenge"
        case expiresAt = "expires_at"
    }

    /// Whether this challenge is worth signing at `date`.
    ///
    /// A challenge with no stated expiry is usable: a server that does not say
    /// is a server that has not delegated the decision.
    package func isUsable(at date: Date) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt > date
    }
}

// MARK: - The two calls attestation needs

/// The server side of App Attest, as this app needs it.
///
/// Two calls, and neither of them goes through `APIClient`. That is not a
/// layering nicety — it is the only arrangement that terminates. The client is
/// what attaches attestation headers to a request, so a challenge fetched
/// through the client would itself need a challenge, which would need a
/// challenge. Both calls here go straight to the pinned `URLSession` the
/// composition root hands over, which is also why they still get certificate
/// pinning: the session is the pinned one, not a second one built here.
///
/// They are unauthenticated by design. Attestation proves the *app*, not the
/// user, and requiring an access token to attest would mean a sign-in that
/// cannot be attested — which is the request an attacker most wants to forge.
package protocol AttestationServing: Sendable {

    /// Asks for a fresh challenge.
    func challenge() async throws -> AttestationChallenge

    /// Registers a newly attested key, once per key.
    ///
    /// - Throws: `AttestationError.keyRejected` when the server will not accept
    ///   the attestation. That is terminal for this key: the right response is
    ///   to discard the identifier and start again, not to retry.
    func registerKey(_ keyID: String, attestation: Data, challenge: String) async throws
}

// MARK: - Errors

/// What can go wrong on the way to an attested request.
///
/// Plain English rather than a `String` catalog entry, following
/// `BackgroundRefreshFailure`: none of this is ever shown to a user. Under
/// `AttestationEnforcement.reportOnly` these are logged and swallowed, and
/// under `.enforced` they surface to a caller that already renders
/// `APIError.networkUnavailable` prose for the human in front of it.
package enum AttestationError: LocalizedError, Hashable, Sendable {

    /// This device cannot attest: a simulator, a missing Secure Enclave, or a
    /// build signed by a team that does not own the app ID.
    case unsupportedDevice

    /// The server would not certify the key. Terminal for that key.
    case keyRejected(statusCode: Int)

    /// The challenge endpoint answered with something that is not a challenge.
    case challengeUnavailable(statusCode: Int)

    /// The response decoded, but the challenge in it had already expired.
    case challengeExpired

    /// Attestation is required for this request and could not be produced.
    case unattested

    package var errorDescription: String? {
        switch self {
        case .unsupportedDevice:
            "This device cannot produce App Attest assertions."
        case let .keyRejected(statusCode):
            "The server refused to register the attestation key (HTTP \(statusCode))."
        case let .challengeUnavailable(statusCode):
            "The server did not issue an attestation challenge (HTTP \(statusCode))."
        case .challengeExpired:
            "The attestation challenge expired before it could be used."
        case .unattested:
            "The request requires an App Attest assertion and none could be produced."
        }
    }
}

// MARK: - The live implementation

/// `AttestationServing` over the app's pinned `URLSession`.
///
/// It builds its own `URLRequest`s rather than borrowing `APIEndpoint`, for the
/// reason above: everything that goes through the endpoint type goes through
/// the client, and the client is what calls this.
package struct URLSessionAttestationService: AttestationServing {

    /// Where the challenge is fetched from, relative to `baseURL`.
    package static let challengePath = "/attest/challenge"

    /// Where a new key is registered, relative to `baseURL`.
    package static let keyPath = "/attest/key"

    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// `session` has no default here for the same reason it has none on
    /// `URLSessionAPIClient`: `URLSession.shared` carries no delegate, so a
    /// service that resolved its own session would be the one part of this app
    /// talking to the network unpinned — and the part that hands out the key
    /// material's certification at that.
    package init(
        baseURL: URL,
        session: URLSession,
        decoder: JSONDecoder = .apiDecoder,
        encoder: JSONEncoder = .apiEncoder
    ) {
        self.baseURL = baseURL
        self.session = session
        self.decoder = decoder
        self.encoder = encoder
    }

    package func challenge() async throws -> AttestationChallenge {
        var request = URLRequest(url: baseURL.appendingPathComponent(Self.challengePath))
        request.httpMethod = HTTPMethod.post.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, status) = try await send(request)
        guard status == 200 else { throw AttestationError.challengeUnavailable(statusCode: status) }
        do {
            return try decoder.decode(AttestationChallenge.self, from: data)
        } catch {
            throw AttestationError.challengeUnavailable(statusCode: status)
        }
    }

    package func registerKey(_ keyID: String, attestation: Data, challenge: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(Self.keyPath))
        request.httpMethod = HTTPMethod.post.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(
            AttestationKeyRegistration(keyID: keyID, attestation: attestation, challenge: challenge)
        )

        let (_, status) = try await send(request)
        guard (200...299).contains(status) else {
            throw AttestationError.keyRejected(statusCode: status)
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw APIError.networkUnavailable(urlError)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http.statusCode)
    }
}

// MARK: - The registration body

/// What `registerKey` posts.
///
/// The attestation object is base64 rather than raw CBOR because the body is
/// JSON; `Data`'s own `Codable` conformance already encodes to base64, and this
/// declares it explicitly so a future encoder configuration cannot change the
/// wire format underneath the server.
package struct AttestationKeyRegistration: Encodable, Sendable {
    package let keyID: String
    package let attestation: Data
    package let challenge: String

    package init(keyID: String, attestation: Data, challenge: String) {
        self.keyID = keyID
        self.attestation = attestation
        self.challenge = challenge
    }

    package enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case attestation
        case challenge
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyID, forKey: .keyID)
        try container.encode(attestation.base64EncodedString(), forKey: .attestation)
        try container.encode(challenge, forKey: .challenge)
    }
}

// MARK: - The double

/// A scripted `AttestationServing` for tests and previews.
///
/// It issues a distinct challenge per call, which is the property the code
/// under test depends on: a stub that returned a constant would let a
/// regression that signs a stale challenge pass every test.
package final class StubAttestationService: AttestationServing {

    private struct State: Sendable {
        var attempts: Int = 0
        var issued: Int = 0
        var expiresAt: Date?
        var challengeFailure: AttestationError?
        var registrationFailure: AttestationError?
        var registrations: [Registration] = []
        var challenges: [String] = []
    }

    /// One recorded call to `registerKey`.
    package struct Registration: Hashable, Sendable {
        package let keyID: String
        package let attestation: Data
        package let challenge: String
    }

    private let state: OSAllocatedUnfairLock<State>

    package init(expiresAt: Date? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(expiresAt: expiresAt))
    }

    // MARK: - Arranging

    /// Makes every `challenge()` throw until told otherwise.
    package func failChallenges(with error: AttestationError) {
        state.withLock { $0.challengeFailure = error }
    }

    /// Makes every `registerKey` throw until told otherwise.
    package func failRegistrations(with error: AttestationError) {
        state.withLock { $0.registrationFailure = error }
    }

    /// Stops failing, in either direction.
    package func succeedFromNowOn() {
        state.withLock {
            $0.challengeFailure = nil
            $0.registrationFailure = nil
        }
    }

    // MARK: - Observing

    /// Every key registered, in order.
    package var registrations: [Registration] { state.withLock { $0.registrations } }

    /// Every challenge handed out, in order.
    package var issuedChallenges: [String] { state.withLock { $0.challenges } }

    /// How many times a challenge was asked for, including the times the ask
    /// failed. `issuedChallenges` counts only the successes, which makes it
    /// useless for the one thing the breaker has to be measured against —
    /// whether a second attempt was made at all.
    package var challengeAttempts: Int { state.withLock { $0.attempts } }

    // MARK: - AttestationServing

    package func challenge() async throws -> AttestationChallenge {
        try state.withLock { current in
            current.attempts += 1
            if let failure = current.challengeFailure { throw failure }
            current.issued += 1
            let value = "stub-challenge-\(current.issued)"
            current.challenges.append(value)
            return AttestationChallenge(value: value, expiresAt: current.expiresAt)
        }
    }

    package func registerKey(_ keyID: String, attestation: Data, challenge: String) async throws {
        try state.withLock { current in
            if let failure = current.registrationFailure { throw failure }
            current.registrations.append(
                Registration(keyID: keyID, attestation: attestation, challenge: challenge)
            )
        }
    }
}
