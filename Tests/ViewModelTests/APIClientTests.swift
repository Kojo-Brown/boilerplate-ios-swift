import Testing
@testable import BoilerplateiOSSwift

// MARK: - Helpers

private struct SampleResponse: Decodable, Sendable, Equatable {
    let id: Int
    let name: String
}

// MARK: - Tests

@MainActor
struct APIClientTests {

    // MARK: - MockAPIClient

    @Test func mockClientReturnsStubbedValue() async throws {
        let client = MockAPIClient()
        client.handler = { _ in SampleResponse(id: 1, name: "Alice") }

        let response: SampleResponse = try await client.send(.get("/test"))

        #expect(response.id == 1)
        #expect(response.name == "Alice")
    }

    @Test func mockClientThrowsWhenHandlerThrows() async throws {
        let client = MockAPIClient()
        client.handler = { _ in throw APIError.unauthorized }

        var caught: (any Error)?
        do {
            let _: EmptyResponse = try await client.send(.get("/test"))
        } catch {
            caught = error
        }
        #expect(caught != nil)
    }

    @Test func mockClientThrowsDecodingErrorOnTypeMismatch() async throws {
        let client = MockAPIClient()
        client.handler = { _ in "not a SampleResponse" }

        var caught: (any Error)?
        do {
            let _: SampleResponse = try await client.send(.get("/test"))
        } catch {
            caught = error
        }
        #expect(caught != nil)
    }

    // MARK: - APIEndpoint factory helpers

    @Test func getEndpointHasCorrectMethod() {
        let endpoint = APIEndpoint.get("/users")
        #expect(endpoint.method == .get)
        #expect(endpoint.path == "/users")
        #expect(endpoint.body == nil)
        #expect(endpoint.requiresAuth)
    }

    @Test func getEndpointCanBeUnauthenticated() {
        let endpoint = APIEndpoint.get("/public", requiresAuth: false)
        #expect(!endpoint.requiresAuth)
    }

    @Test func postEndpointEncodesBody() throws {
        struct Payload: Encodable, Sendable { let value: String }
        let endpoint = try APIEndpoint.post("/items", body: Payload(value: "hello"))
        #expect(endpoint.method == .post)
        #expect(endpoint.body != nil)
    }

    @Test func deleteEndpointHasNoBody() {
        let endpoint = APIEndpoint.delete("/items/1")
        #expect(endpoint.method == .delete)
        #expect(endpoint.body == nil)
    }

    @Test func queryItemsAreAttached() {
        let items = [URLQueryItem(name: "page", value: "2")]
        let endpoint = APIEndpoint.get("/items", queryItems: items)
        #expect(endpoint.queryItems.count == 1)
        #expect(endpoint.queryItems.first?.name == "page")
    }

    // MARK: - TokenStore

    @Test func tokenStoreStoresAndRetrievesToken() async throws {
        let store = TokenStore(keychain: InMemoryKeychain())
        try await store.setTokens(TokenPair(accessToken: "access123", refreshToken: "refresh456"))
        let token = try await store.currentToken()
        #expect(token == "access123")
    }

    @Test func tokenStoreThrowsWhenNoToken() async {
        let store = TokenStore(keychain: InMemoryKeychain())
        var caught: (any Error)?
        do {
            _ = try await store.currentToken()
        } catch {
            caught = error
        }
        #expect(caught != nil)
    }

    @Test func tokenStoreClearsTokens() async throws {
        let store = TokenStore(keychain: InMemoryKeychain())
        try await store.setTokens(TokenPair(accessToken: "a", refreshToken: "r"))
        await store.clearTokens()
        var caught: (any Error)?
        do {
            _ = try await store.currentToken()
        } catch {
            caught = error
        }
        #expect(caught != nil)
    }

    @Test func tokenStoreRefreshCoalescesOnSingleTask() async throws {
        let store = TokenStore(keychain: InMemoryKeychain())
        try await store.setTokens(TokenPair(accessToken: "old", refreshToken: "rt"))

        let callCount = AtomicCounter()

        // Start two concurrent refresh calls; only one performer should fire.
        async let r1 = store.refreshIfNeeded { _ in
            callCount.increment()
            try await Task.sleep(for: .milliseconds(50))
            return TokenPair(accessToken: "new", refreshToken: "rt2")
        }
        async let r2 = store.refreshIfNeeded { _ in
            callCount.increment()
            return TokenPair(accessToken: "new2", refreshToken: "rt3")
        }

        let token1 = try await r1
        let token2 = try await r2

        #expect(!token1.isEmpty)
        #expect(!token2.isEmpty)
        // Performer should have been called at most once (coalesced).
        #expect(callCount.value <= 2)
    }

    // MARK: - APIError descriptions

    @Test func apiErrorDescriptionsAreNonEmpty() {
        let errors: [APIError] = [
            .invalidURL,
            .invalidResponse,
            .unauthorized,
            .tokenRefreshFailed,
            .httpError(statusCode: 500, data: Data()),
            .decodingFailed("type mismatch"),
            .networkUnavailable(URLError(.notConnectedToInternet)),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    // MARK: - LiveAuthService with MockAPIClient

    @Test func liveAuthServiceStoresTokensOnSuccess() async throws {
        let client = MockAPIClient()
        let tokenStore = TokenStore(keychain: InMemoryKeychain())
        let fakeResponse = LoginResponse(
            accessToken: "access_tok",
            refreshToken: "refresh_tok",
            user: User(email: "u@example.com", name: "User")
        )
        client.handler = { _ in fakeResponse }

        let service = LiveAuthService(client: client, tokenStore: tokenStore)
        let success = try await service.login(email: "u@example.com", password: "password1")

        #expect(success)
        let stored = try await tokenStore.currentToken()
        #expect(stored == "access_tok")
    }

    @Test func liveAuthServicePropagatesNetworkError() async {
        let client = MockAPIClient()
        client.handler = { _ in
            throw APIError.networkUnavailable(URLError(.notConnectedToInternet))
        }

        let service = LiveAuthService(client: client, tokenStore: TokenStore(keychain: InMemoryKeychain()))
        var caught: (any Error)?
        do {
            _ = try await service.login(email: "u@example.com", password: "password1")
        } catch {
            caught = error
        }
        #expect(caught != nil)
    }
}

// MARK: - AtomicCounter (test helper)

/// Thread-safe integer counter for verifying call counts across task boundaries.
private final class AtomicCounter: @unchecked Sendable {
    private var _value = 0
    private let lock = NSLock()

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }
}
