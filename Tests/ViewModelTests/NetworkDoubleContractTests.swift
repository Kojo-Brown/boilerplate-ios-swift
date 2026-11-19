import Foundation
import os
import Testing
@testable import Core
@testable import Networking

// MARK: - A stub of this suite's own

/// The same idea as `StubURLProtocol` and `AttestationStubURLProtocol`, and
/// deliberately a third class.
///
/// A `URLProtocol` subclass is instantiated by `URLSession`, so its script has
/// to be static, and `.serialized` only orders the tests *within* one suite —
/// Swift Testing runs suites in parallel with each other. Sharing a stub
/// between two serialized suites would let this one's script be consumed by the
/// other's requests, on a schedule that changes with the runner's core count.
/// Three classes, three scripts, three sessions, no interleaving.
///
/// It scripts `MockAPIClient.Exchange` rather than declaring an `Exchange` of
/// its own, which is the one difference from its two neighbours and the point
/// of the suite: the table below arms the transport and the double from the
/// *same* values, so a difference in the outcome cannot be a difference in what
/// the two were asked.
class ContractStubURLProtocol: URLProtocol {

    private struct State: Sendable {
        var scripted: [MockAPIClient.Exchange] = []
        var recorded: [URLRequest] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func script(_ exchanges: [MockAPIClient.Exchange]) {
        state.withLock { $0 = State(scripted: exchanges, recorded: []) }
    }

    static var recordedRequests: [URLRequest] {
        state.withLock { $0.recorded }
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let next = ContractStubURLProtocol.state.withLock { current -> MockAPIClient.Exchange? in
            current.recorded.append(request)
            return current.scripted.isEmpty ? nil : current.scripted.removeFirst()
        }

        guard let next, let url = request.url else {
            // An unscripted request is a test bug. It fails as a transport
            // error rather than as a status, because there is no status that
            // would say "the test forgot to script this".
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

// MARK: - The outcome a caller can observe

/// `APIError` reduced to the part a contract can assert about.
///
/// `decodingFailed` drops its message on purpose. It carries
/// `DecodingError.localizedDescription`, which is a string Foundation owns and
/// may reword between OS versions; asserting on it would make this suite fail
/// on an Xcode upgrade and say nothing about the double. The *case* is the
/// contract — a caller branches on it — and the case is what is compared.
enum ContractAPIFailure: Equatable, Sendable {
    case unauthorized
    case http(statusCode: Int, body: Data)
    case decodingFailed
    case invalidResponse
    case invalidURL
    case tokenRefreshFailed
    case networkUnavailable

    /// Anything that is not an `APIError` at all, named by its type so a
    /// failure message says what arrived instead.
    case foreign(String)

    init(_ error: any Error) {
        guard let api = error as? APIError else {
            self = .foreign(String(describing: type(of: error)))
            return
        }
        switch api {
        case .unauthorized:
            self = .unauthorized
        case let .httpError(statusCode, data):
            self = .http(statusCode: statusCode, body: data)
        case .decodingFailed:
            self = .decodingFailed
        case .invalidResponse:
            self = .invalidResponse
        case .invalidURL:
            self = .invalidURL
        case .tokenRefreshFailed:
            self = .tokenRefreshFailed
        case .networkUnavailable:
            self = .networkUnavailable
        }
    }
}

/// What one `send` produced: the value, or the failure, and nothing about how.
enum ContractSendOutcome<Value: Equatable & Sendable>: Equatable, Sendable {
    case value(Value)
    case failure(ContractAPIFailure)
}

/// Runs one `send` through whichever client it is handed and reports the
/// outcome instead of propagating it.
///
/// Taking `any APIClient` is what makes the two halves one test: the generic
/// `send` is callable on the existential, so the transport and the double are
/// driven by identical code rather than by two code paths that look alike.
private func outcome<Response: Decodable & Sendable & Equatable>(
    _ type: Response.Type,
    from client: any APIClient,
    sending endpoint: APIEndpoint
) async -> ContractSendOutcome<Response> {
    do {
        let value: Response = try await client.send(endpoint)
        return .value(value)
    } catch {
        return .failure(ContractAPIFailure(error))
    }
}

// MARK: - Fixtures

private let contractBaseURL = URL(string: "https://contract.invalid/v1")!

private let contractUserJSON = """
{"id": "00000000-0000-0000-0000-00000000ACE1", "email": "contract@example.invalid", "name": "Contract"}
"""

private let contractUser = User(
    id: UUID(uuidString: "00000000-0000-0000-0000-00000000ACE1")!,
    email: "contract@example.invalid",
    name: "Contract"
)

/// What a refresh answers with. Obviously fake, like every other credential in
/// this bundle.
private let refreshedTokensJSON = """
{"access_token": "mock-access-token-2", "refresh_token": "mock-refresh-token-2"}
"""

private let serverErrorBody = Data(#"{"error": "nope"}"#.utf8)

/// A transport pointed at the stub, with tokens already in place so that the
/// refresh path is reachable rather than failing for want of a refresh token.
@MainActor
private func makeTransport() async throws -> URLSessionAPIClient {
    let store = TokenStore(keychain: InMemoryKeychain())
    try await store.setTokens(
        TokenPair(accessToken: "mock-access-token", refreshToken: "mock-refresh-token")
    )
    return URLSessionAPIClient(
        baseURL: contractBaseURL,
        tokenStore: store,
        session: ContractStubURLProtocol.session,
        attestor: UnattestedRequests()
    )
}

// MARK: - The table

/// One scripted exchange, the request it answers, and the outcome both
/// implementations owe a caller.
///
/// `expected` is written out rather than derived, so the suite says what the
/// contract *is* instead of only that the two agree. Two implementations that
/// are wrong in the same way would satisfy "they agree" and fail this.
/// Internal rather than `private`, which is not a style choice: a `@Test`
/// method is internal, and Swift refuses an internal method whose parameter
/// uses a private type. `PinningFixture` is internal for the same reason.
struct ContractWireScenario: Sendable, CustomTestStringConvertible {
    let name: String
    let exchanges: [MockAPIClient.Exchange]
    let endpoint: APIEndpoint
    let expected: ContractSendOutcome<User>

    var testDescription: String { name }

    static let all: [ContractWireScenario] = [
        ContractWireScenario(
            name: "200 carrying the row",
            exchanges: [.success(contractUserJSON)],
            endpoint: .get("/users/me"),
            expected: .value(contractUser)
        ),
        // 299 is in range and 300 is not, and the boundary is a `switch` case
        // in one place now. Before the extraction it was a literal in the
        // transport and absent from the double entirely.
        ContractWireScenario(
            name: "299 is still a success",
            exchanges: [MockAPIClient.Exchange(statusCode: 299, body: Data(contractUserJSON.utf8))],
            endpoint: .get("/users/me"),
            expected: .value(contractUser)
        ),
        ContractWireScenario(
            name: "200 carrying a body that is not the row",
            exchanges: [.success(#"{"unexpected": true}"#)],
            endpoint: .get("/users/me"),
            expected: .failure(.decodingFailed)
        ),
        // The empty-body case, which is not hypothetical: `deleteAccount()`
        // decodes `EmptyResponse` from whatever a 204 carries, and
        // `APICrashReportUploaderTests` already documents that a 2xx whose body
        // cannot be decoded is the normal path for one endpoint here. Both
        // implementations report it the same way, which is what this pins; that
        // the shared answer is `decodingFailed` rather than a success is a
        // property of the transport and a note in `docs/test-doubles.md`.
        ContractWireScenario(
            name: "200 carrying nothing at all",
            exchanges: [MockAPIClient.Exchange(statusCode: 200)],
            endpoint: .get("/users/me"),
            expected: .failure(.decodingFailed)
        ),
        ContractWireScenario(
            name: "404 with a body the server explained itself in",
            exchanges: [MockAPIClient.Exchange(statusCode: 404, body: serverErrorBody)],
            endpoint: .get("/users/me"),
            expected: .failure(.http(statusCode: 404, body: serverErrorBody))
        ),
        ContractWireScenario(
            name: "500 with no body",
            exchanges: [MockAPIClient.Exchange(statusCode: 500)],
            endpoint: .get("/users/me"),
            expected: .failure(.http(statusCode: 500, body: Data()))
        ),
        // The one 401 both halves answer identically, because `requiresAuth`
        // is what gates the refresh: an endpoint that sends no credential has
        // no credential to refresh.
        ContractWireScenario(
            name: "401 on an endpoint that needs no auth",
            exchanges: [.unauthorized],
            endpoint: .get("/public", requiresAuth: false),
            expected: .failure(.unauthorized)
        ),
    ]
}

// MARK: - The contract

/// The behaviour `MockAPIClient` promises by conforming, asserted against the
/// transport it replaces.
///
/// ## What was missing before this item
///
/// The double was armed with a closure returning `Any`, so a test wrote the
/// *outcome* directly and the transport's own rules were nowhere in it. That
/// makes a whole class of test quietly wrong rather than red: a handler that
/// returns a decoded `User` for what the server answered 500 to, or throws
/// `unauthorized` where the transport throws `httpError`, tests the caller
/// against a server that cannot exist. `script(_:)` is the repair — it is armed
/// in status codes and bodies — and this suite is the proof, because a double
/// that maps them differently from the transport is exactly what it fails on.
///
/// Serialized for the reason `ContractStubURLProtocol` documents: the script is
/// static, so two of these tests in flight together would consume each other's
/// answers.
@Suite("Double contract — network", .serialized)
@MainActor
struct NetworkDoubleContractTests {

    @Test("The double and the transport answer one script the same way", arguments: ContractWireScenario.all)
    func theDoubleAgreesWithTheTransport(scenario: ContractWireScenario) async throws {
        ContractStubURLProtocol.script(scenario.exchanges)
        let transport = try await makeTransport()
        let fromTransport = await outcome(User.self, from: transport, sending: scenario.endpoint)

        let double = MockAPIClient()
        double.script(scenario.exchanges)
        let fromDouble = await outcome(User.self, from: double, sending: scenario.endpoint)

        #expect(fromTransport == scenario.expected, "transport")
        #expect(fromDouble == scenario.expected, "double")
        #expect(fromTransport == fromDouble, "transport vs double")
    }

    /// The one path the double deliberately does not model, pinned as a
    /// divergence rather than left to be discovered.
    ///
    /// A 401 on an authenticated endpoint sends the transport to `/auth/refresh`
    /// and then re-sends the original request, so one `send` is three exchanges
    /// on the wire. The double does not do that, and should not: replacing the
    /// client means the client's retry is the thing being replaced, so a double
    /// that reimplemented it would be asserting that a copy of the logic agrees
    /// with the logic.
    ///
    /// What that costs is written down here instead: a test that needs the
    /// refresh-and-retry has to use `URLSessionAPIClient` over a `URLProtocol`
    /// stub, as `APIClientTests` and `IdempotencyTransportTests` do. A test that
    /// scripts `.unauthorized` on the double is testing what a caller sees when
    /// the refresh has already failed.
    @Test("The 401 refresh-and-retry belongs to the transport, not the double")
    func theRefreshRetryIsNotModelledByTheDouble() async throws {
        ContractStubURLProtocol.script([
            .unauthorized,
            .success(refreshedTokensJSON),
            .success(contractUserJSON),
        ])
        let transport = try await makeTransport()
        let fromTransport = await outcome(User.self, from: transport, sending: .get("/users/me"))

        let double = MockAPIClient()
        double.script([.unauthorized])
        let fromDouble = await outcome(User.self, from: double, sending: .get("/users/me"))

        #expect(fromTransport == .value(contractUser))
        #expect(fromDouble == .failure(.unauthorized))

        // Three deliveries for one `send`: the 401, the refresh, the retry.
        #expect(ContractStubURLProtocol.recordedRequests.count == 3)
        #expect(double.recordedEndpoints.count == 1)
    }

    /// A 401 that survives the refresh is `unauthorized` on both halves, which
    /// is the point at which the divergence above closes: once the retry has
    /// been spent, the two answer alike.
    @Test("A 401 that outlives the retry is unauthorized either way")
    func aPersistent401IsUnauthorized() async throws {
        ContractStubURLProtocol.script([
            .unauthorized,
            .success(refreshedTokensJSON),
            .unauthorized,
        ])
        let transport = try await makeTransport()
        let fromTransport = await outcome(User.self, from: transport, sending: .get("/users/me"))

        let double = MockAPIClient()
        double.script([.unauthorized])
        let fromDouble = await outcome(User.self, from: double, sending: .get("/users/me"))

        #expect(fromTransport == .failure(.unauthorized))
        #expect(fromDouble == .failure(.unauthorized))
    }

    /// The double records what the transport puts on the wire, so a test can
    /// assert *which* request was made without a `URLProtocol`.
    ///
    /// Paths rather than whole URLs: the double is handed an `APIEndpoint` and
    /// never sees a `baseURL`, so the shared part of the claim is the path the
    /// endpoint named.
    @Test("The double records the request the transport would send")
    func theDoubleRecordsWhatTheWireSees() async throws {
        let endpoint = APIEndpoint.get("/users/me")

        ContractStubURLProtocol.script([.success(contractUserJSON)])
        let transport = try await makeTransport()
        let _: User = try await transport.send(endpoint)

        let double = MockAPIClient()
        double.script([.success(contractUserJSON)])
        let _: User = try await double.send(endpoint)

        let wirePaths = ContractStubURLProtocol.recordedRequests.compactMap { $0.url?.path }
        #expect(wirePaths.count == 1)
        let wirePath = try #require(wirePaths.first)
        #expect(wirePath.hasSuffix("/users/me"))
        #expect(double.recordedEndpoints.map(\.path) == ["/users/me"])
        #expect(double.recordedEndpoints.map(\.method) == [.get])
    }

    /// A send the test did not script is a test bug, and it has to arrive as
    /// one. Reporting it as an `APIError` would let a retry decorator swallow
    /// it and a test pass while measuring nothing.
    @Test("A send the test did not script is not a server failure")
    func anUnscriptedSendIsATestBug() async {
        let double = MockAPIClient()
        double.script([])

        await #expect(throws: MockAPIClient.ScriptExhausted.self) {
            let _: User = try await double.send(.get("/users/me"))
        }
    }

    /// Scripting is an addition, not a replacement: the handler is still how
    /// most of this bundle arms the double, and this is the pin that says so.
    @Test("A double that was never scripted still answers from its handler")
    func theHandlerStillAnswers() async throws {
        let double = MockAPIClient()
        double.handler = { _ in contractUser }

        let user: User = try await double.send(.get("/users/me"))

        #expect(user == contractUser)
        #expect(double.recordedEndpoints.map(\.path) == ["/users/me"])
    }
}
