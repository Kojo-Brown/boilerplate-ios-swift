import Core
import Foundation

// MARK: - URLSession API client

/// Concrete `APIClient` backed by `URLSession`.
///
/// - Attaches `Authorization: Bearer <token>` to every authenticated request.
/// - Attaches `Idempotency-Key` when the endpoint carries one.
/// - On a 401 response, calls `/auth/refresh` once via `TokenStore.refreshIfNeeded`,
///   then retries the original request with the new token.
/// - Concurrent 401s coalesce to a single refresh via actor-isolated `TokenStore`.
///
/// ## The refresh retry is a second delivery, and it always was
///
/// The 401 path below re-sends the request. That is the one duplicate this type
/// produces on its own, it is invisible to every retry policy layered above it —
/// `RetryingUserRepository` sees one call — and a 401 arriving *after* the
/// server acted is not exotic: an access token that expires between the request
/// being authorised and the response being written produces exactly it.
///
/// Nothing here can make that safe. What it can do is not throw away the one
/// thing that does: the retry copies the original `URLRequest` and replaces only
/// the `Authorization` header, so an `Idempotency-Key` set on the first delivery
/// is still on the second and the server can recognise the pair.
package struct URLSessionAPIClient: APIClient {
    package let baseURL: URL
    private let session: URLSession
    private let tokenStore: any TokenStoring
    private let attestor: any RequestAttesting
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// `baseURL`, `tokenStore` and `session` carry no defaults: they are the
    /// three things that decide *which server* this talks to, *whose tokens*
    /// it sends, and *what it will accept as that server*, and all three are
    /// the composition root's to answer — see `AppContainer`.
    ///
    /// `session` lost its `.shared` default in Phase 11 item 2, when the app
    /// started pinning. The default was not wrong before and is not a style
    /// question now: `URLSession.shared` cannot carry a delegate, so a client
    /// built without naming a session is a client with no certificate
    /// pinning — and one that works perfectly, against the right server, on
    /// every device, right up until the connection it is meant to refuse. A
    /// default that silently opts out of a security control is a default that
    /// has to be spelled out at the call site instead.
    ///
    /// `decoder` and `encoder` keep theirs. They are configuration rather than
    /// collaborators: neither appears in the audited surface of
    /// `docs/solid.md`, substituting one changes how a request is encoded
    /// rather than who answers it, and `.apiDecoder`/`.apiEncoder` are the
    /// only answers this package has ever wanted.
    ///
    /// `attestor` carries no default either, and for the same shape of reason
    /// one step further on. Pinning decides what the app will accept as the
    /// server; attestation decides what the server will accept as the app, and
    /// `UnattestedRequests()` — the do-nothing implementation — is exactly what
    /// a forgotten argument would have resolved to. Written out, it is a line
    /// in the composition root that says the app is not attesting yet;
    /// defaulted, it is nothing at all. See `AppAttestor`.
    package init(
        baseURL: URL,
        tokenStore: any TokenStoring,
        session: URLSession,
        attestor: any RequestAttesting,
        decoder: JSONDecoder = .apiDecoder,
        encoder: JSONEncoder = .apiEncoder
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenStore = tokenStore
        self.attestor = attestor
        self.decoder = decoder
        self.encoder = encoder
    }

    // MARK: - APIClient

    package func send<Response: Decodable & Sendable>(_ endpoint: APIEndpoint) async throws -> Response {
        let data = try await performRequest(endpoint)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch let error as DecodingError {
            throw APIError.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Request execution

    private func performRequest(_ endpoint: APIEndpoint) async throws -> Data {
        let request = try await buildRequest(endpoint)
        let (data, http) = try await send(attesting: request)

        // On 401, refresh tokens and retry once.
        if http.statusCode == 401 && endpoint.requiresAuth {
            let newToken = try await refreshTokens()
            var retryRequest = request
            retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")

            let (retryData, retryHTTP) = try await send(attesting: retryRequest)
            return try validate(retryData, response: retryHTTP)
        }

        return try validate(data, response: http)
    }

    /// Attaches an assertion, if there is one to attach, and sends.
    ///
    /// Every delivery goes through here, and that is the point: the 401 retry
    /// above re-enters it rather than re-sending the request it already built,
    /// so the second delivery carries a *new* assertion over a *new*
    /// challenge. Copying the headers across would be the natural-looking
    /// version and it is the one that breaks — an App Attest assertion
    /// increments a counter inside the Secure Enclave, a server doing replay
    /// detection refuses any counter it has already accepted, and the retry
    /// would therefore be rejected as an attack by the same server that asked
    /// for the token to be refreshed.
    ///
    /// The `Authorization` header is the opposite case and is deliberately
    /// copied: it is what the retry exists to change. So is
    /// `Idempotency-Key` — see the note on this type — which has to survive
    /// unchanged for the server to recognise the two deliveries as one
    /// request.
    private func send(attesting request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var outgoing = request
        if let attestation = try await attestor.attestation(for: request) {
            attestation.apply(to: &outgoing)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: outgoing)
        } catch let urlError as URLError {
            throw APIError.networkUnavailable(urlError)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        return (data, http)
    }

    // MARK: - Request building

    private func buildRequest(_ endpoint: APIEndpoint) async throws -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(endpoint.path),
            resolvingAgainstBaseURL: false
        )
        if !endpoint.queryItems.isEmpty {
            components?.queryItems = endpoint.queryItems
        }
        guard let url = components?.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body = endpoint.body {
            request.httpBody = body
        }
        if let key = endpoint.idempotencyKey {
            request.setValue(key.rawValue, forHTTPHeaderField: IdempotencyKey.headerField)
        }
        if endpoint.requiresAuth {
            let token = try await tokenStore.currentToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Token refresh

    private func refreshTokens() async throws -> String {
        try await tokenStore.refreshIfNeeded { [self] refreshToken in
            var request = URLRequest(url: baseURL.appendingPathComponent("/auth/refresh"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(TokenRefreshRequest(refreshToken: refreshToken))

            // Attested like everything else, and this is the request that most
            // needs it: it is the one that turns a stolen refresh token into a
            // fresh access token, and the one an attacker replaying captured
            // traffic would reach for first.
            let (data, http) = try await send(attesting: request)
            guard http.statusCode == 200 else {
                throw APIError.tokenRefreshFailed
            }
            return try decoder.decode(TokenPair.self, from: data)
        }
    }

    // MARK: - Status validation

    private func validate(_ data: Data, response: HTTPURLResponse) throws -> Data {
        switch response.statusCode {
        case 200...299:
            return data
        case 401:
            throw APIError.unauthorized
        default:
            throw APIError.httpError(statusCode: response.statusCode, data: data)
        }
    }
}
