import Foundation
import os
import Testing
@testable import Core
@testable import Networking

// MARK: - A stub of this suite's own

/// The same idea as `StubURLProtocol` and deliberately a separate class.
///
/// A `URLProtocol` subclass is instantiated by `URLSession`, so its script has
/// to be static, and `.serialized` only orders the tests *within* one suite —
/// Swift Testing runs suites in parallel with each other. Sharing
/// `StubURLProtocol` between two serialized suites would therefore let this
/// one's script be consumed by the other's requests, on a schedule that
/// changes with the runner's core count. Two classes, two scripts, two
/// sessions, no interleaving.
class AttestationStubURLProtocol: URLProtocol {

    struct Exchange: Sendable {
        let statusCode: Int
        let body: Data

        static func success(_ json: String) -> Exchange {
            Exchange(statusCode: 200, body: Data(json.utf8))
        }

        static let unauthorized = Exchange(statusCode: 401, body: Data())
    }

    private struct State: Sendable {
        var scripted: [Exchange] = []
        var recorded: [URLRequest] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func script(_ exchanges: [Exchange]) {
        state.withLock { $0 = State(scripted: exchanges, recorded: []) }
    }

    static var recordedRequests: [URLRequest] {
        state.withLock { $0.recorded }
    }

    /// The value of `header` on each recorded request, `nil` where absent.
    static func recordedValues(of header: String) -> [String?] {
        recordedRequests.map { $0.value(forHTTPHeaderField: header) }
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AttestationStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let next = AttestationStubURLProtocol.state.withLock { current -> Exchange? in
            current.recorded.append(request)
            return current.scripted.isEmpty ? nil : current.scripted.removeFirst()
        }

        guard let next, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: next.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Fixtures

private let attestationBaseURL = URL(string: "https://stub.invalid/v1")!

private let refreshedTokensPayload = """
{"access_token": "mock-access-token-2", "refresh_token": "mock-refresh-token-2"}
"""

private func makeAttestedClient(
    tokenStore: any TokenStoring,
    attestor: any RequestAttesting
) -> URLSessionAPIClient {
    URLSessionAPIClient(
        baseURL: attestationBaseURL,
        tokenStore: tokenStore,
        session: AttestationStubURLProtocol.session,
        attestor: attestor
    )
}

private func makeTokenStore() async throws -> TokenStore {
    let store = TokenStore(keychain: InMemoryKeychain())
    try await store.setTokens(
        TokenPair(accessToken: "mock-access-token", refreshToken: "mock-refresh-token")
    )
    return store
}

private func makeAttestor(enforcement: AttestationEnforcement = .reportOnly) -> AppAttestor {
    AppAttestor(
        service: StubAppAttestService(),
        server: StubAttestationService(),
        keychain: InMemoryKeychain(),
        reporter: RecordingAttestationReporter(),
        enforcement: enforcement
    )
}

// MARK: - On the wire

/// Serialized for the reason `AttestationStubURLProtocol` documents: the script
/// is static because `URLSession` builds the protocol instances itself.
@Suite("App Attest — on the wire", .serialized)
struct AttestationTransportTests {

    @Test("An attested request carries every declared header")
    func attestedRequestCarriesTheHeaders() async throws {
        AttestationStubURLProtocol.script([.success("{}")])
        let tokenStore = try await makeTokenStore()
        let client = makeAttestedClient(tokenStore: tokenStore, attestor: makeAttestor())

        _ = try await client.sendEmpty(.get("/users"))

        let recorded = try #require(AttestationStubURLProtocol.recordedRequests.first)
        for field in AttestationHeaderField.all {
            #expect(recorded.value(forHTTPHeaderField: field) != nil)
        }
        #expect(
            recorded.value(forHTTPHeaderField: AttestationHeaderField.format)
                == AttestationClientData.format
        )
    }

    @Test("A request sent through the do-nothing attestor carries none of them")
    func unattestedRequestCarriesNoHeaders() async throws {
        AttestationStubURLProtocol.script([.success("{}")])
        let tokenStore = try await makeTokenStore()
        let client = makeAttestedClient(tokenStore: tokenStore, attestor: UnattestedRequests())

        _ = try await client.sendEmpty(.get("/users"))

        let recorded = try #require(AttestationStubURLProtocol.recordedRequests.first)
        for field in AttestationHeaderField.all {
            #expect(recorded.value(forHTTPHeaderField: field) == nil)
        }
    }

    /// The property that makes the 401 path survive a server doing replay
    /// detection. An App Attest assertion increments a counter in the Secure
    /// Enclave and a verifying server refuses a counter it has already
    /// accepted, so a retry that copied the first delivery's headers would be
    /// rejected as an attack by the very server that asked for the refresh.
    ///
    /// The `Idempotency-Key` is the opposite requirement in the same request —
    /// it must be *identical* across the two deliveries — and both are asserted
    /// here together, because the obvious implementations of one break the
    /// other.
    @Test("The token-refresh retry is re-attested, and keeps its idempotency key")
    func retryIsReattested() async throws {
        AttestationStubURLProtocol.script([
            .unauthorized,
            .success(refreshedTokensPayload),
            .success("{}"),
        ])
        let tokenStore = try await makeTokenStore()
        let client = makeAttestedClient(tokenStore: tokenStore, attestor: makeAttestor())
        let key = IdempotencyKey()
        let endpoint = try APIEndpoint.post("/transfers", body: ["amount": 1], idempotencyKey: key)

        _ = try await client.sendEmpty(endpoint)

        let recorded = AttestationStubURLProtocol.recordedRequests
        #expect(recorded.count == 3)

        let assertions = AttestationStubURLProtocol
            .recordedValues(of: AttestationHeaderField.assertion)
            .compactMap { $0 }
        #expect(assertions.count == 3)
        #expect(Set(assertions).count == 3)

        let challenges = AttestationStubURLProtocol
            .recordedValues(of: AttestationHeaderField.challenge)
            .compactMap { $0 }
        #expect(challenges.count == 3)
        #expect(Set(challenges).count == 3)

        let keys: [String?] = [key.rawValue, nil, key.rawValue]
        #expect(AttestationStubURLProtocol.recordedValues(of: IdempotencyKey.headerField) == keys)

        let authorization = recorded[2].value(forHTTPHeaderField: "Authorization")
        #expect(authorization == "Bearer mock-access-token-2")
    }

    /// Under report-only an attestor that cannot attest must not cost the app a
    /// request. The stub's script has exactly one answer, so a second request
    /// would fail the test rather than pass it quietly.
    @Test("A failing attestor does not stop the request under report-only")
    func failingAttestorDoesNotStopTheRequest() async throws {
        AttestationStubURLProtocol.script([.success("{}")])
        let server = StubAttestationService()
        server.failChallenges(with: .challengeUnavailable(statusCode: 503))
        let attestor = AppAttestor(
            service: StubAppAttestService(),
            server: server,
            keychain: InMemoryKeychain(),
            reporter: RecordingAttestationReporter(),
            enforcement: .reportOnly
        )
        let tokenStore = try await makeTokenStore()
        let client = makeAttestedClient(tokenStore: tokenStore, attestor: attestor)

        _ = try await client.sendEmpty(.get("/users"))

        let recorded = try #require(AttestationStubURLProtocol.recordedRequests.first)
        #expect(recorded.value(forHTTPHeaderField: AttestationHeaderField.assertion) == nil)
        #expect(AttestationStubURLProtocol.recordedRequests.count == 1)
    }

    @Test("Under enforcement a request that cannot be attested is never sent")
    func enforcedAttestationStopsTheRequest() async throws {
        AttestationStubURLProtocol.script([.success("{}")])
        let server = StubAttestationService()
        server.failChallenges(with: .challengeUnavailable(statusCode: 503))
        let attestor = AppAttestor(
            service: StubAppAttestService(),
            server: server,
            keychain: InMemoryKeychain(),
            reporter: RecordingAttestationReporter(),
            enforcement: .enforced
        )
        let tokenStore = try await makeTokenStore()
        let client = makeAttestedClient(tokenStore: tokenStore, attestor: attestor)

        await #expect(throws: (any Error).self) {
            _ = try await client.sendEmpty(.get("/users"))
        }
        #expect(AttestationStubURLProtocol.recordedRequests.isEmpty)
    }
}
