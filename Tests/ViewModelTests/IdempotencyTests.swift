import Foundation
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Networking

// MARK: - Fixtures

/// A profile response, as the API would send it.
private func userJSON(id: UUID = UUID(), name: String) -> String {
    """
    {"id":"\(id.uuidString)","email":"ada@example.invalid","name":"\(name)"}
    """
}

private let refreshedTokensJSON = """
{"access_token":"mock-access-token-2","refresh_token":"mock-refresh-token-2"}
"""

private let stubBaseURL = URL(string: "https://api.example.invalid")!

// MARK: - The key itself

@Suite("IdempotencyKey — one key is one intent")
struct IdempotencyKeyTests {

    /// The property the whole mechanism rests on. Two edits must not collide,
    /// and nothing coordinates the minting — so the only thing standing between
    /// two people's profile updates being merged into one on the server is that
    /// 122 random bits do not repeat.
    @Test("Generated keys do not repeat")
    func generatedKeysAreUnique() {
        let keys = (0..<1000).map { _ in IdempotencyKey() }

        #expect(Set(keys).count == 1000)
    }

    /// The generated form has to satisfy the validation applied to an adopted
    /// one, or a key round-tripped through a persisted outbox row would be
    /// rejected on the way back in.
    @Test("A generated key survives a round trip through its own validator")
    func aGeneratedKeyIsAcceptedByItsOwnValidator() throws {
        let generated = IdempotencyKey()

        let adopted = try #require(IdempotencyKey(rawValue: generated.rawValue))

        #expect(adopted == generated)
    }

    /// The value goes into a header verbatim. A key carrying CR/LF would let
    /// whoever supplied it append headers of their own to the request, which is
    /// why the adopting initialiser is failable rather than trusting.
    @Test(
        "A key that could not safely be a header value is rejected",
        arguments: [
            "",
            String(repeating: "k", count: 256),
            "abc\r\nX-Impersonate: admin",
            "abc\ndef",
            "key with spaces",
            "café",
            "key/with/slashes",
        ]
    )
    func unsafeKeysAreRejected(rawValue: String) {
        #expect(IdempotencyKey(rawValue: rawValue) == nil)
    }

    @Test(
        "The unreserved set and the length limit are both accepted at the boundary",
        arguments: [
            "a",
            "AZaz09-._~",
            String(repeating: "k", count: 255),
        ]
    )
    func safeKeysAreAccepted(rawValue: String) {
        #expect(IdempotencyKey(rawValue: rawValue)?.rawValue == rawValue)
    }
}

// MARK: - Where a key may go

@Suite("APIEndpoint — a key belongs to a request, not to a send")
struct IdempotentEndpointTests {

    private struct Payload: Encodable, Sendable {
        let value: String
    }

    @Test("An unsafe method carries the key it was given")
    func writeEndpointsCarryTheKey() throws {
        let key = IdempotencyKey()

        let post = try APIEndpoint.post("/items", body: Payload(value: "x"), idempotencyKey: key)
        let put = try APIEndpoint.put("/items/1", body: Payload(value: "x"), idempotencyKey: key)
        let patch = try APIEndpoint.patch("/items/1", body: Payload(value: "x"), idempotencyKey: key)
        let delete = APIEndpoint.delete("/items/1", idempotencyKey: key)

        #expect(post.idempotencyKey == key)
        #expect(put.idempotencyKey == key)
        #expect(patch.idempotencyKey == key)
        #expect(delete.idempotencyKey == key)
    }

    /// There is no overload that would let one be attached: a `GET` is safe, so
    /// there is no duplicate to collapse, and a key on one is at best noise in
    /// the server's log. The hand-rolled initialiser refuses it with a
    /// precondition, which is not asserted here because a trapping expectation
    /// needs a subprocess and this is a programmer error that cannot be reached
    /// through the factory surface.
    @Test("A read carries none")
    func readEndpointsCarryNoKey() {
        #expect(APIEndpoint.get("/items").idempotencyKey == nil)
    }

    /// A write built without saying anything about idempotency stays exactly as
    /// it was before this item, rather than acquiring a key nobody asked for. A
    /// key minted somewhere the caller cannot see is a key the caller cannot
    /// reuse on the next attempt, which is the failure mode this whole item is
    /// about.
    @Test("A write without an explicit key does not invent one")
    func aWriteWithoutAKeyDoesNotInventOne() throws {
        let endpoint = try APIEndpoint.post("/items", body: Payload(value: "x"))

        #expect(endpoint.idempotencyKey == nil)
    }
}

// MARK: - On the wire

/// Serialized because `StubURLProtocol`'s script is necessarily static — see
/// that type for why.
@Suite("Idempotency on the wire", .serialized)
struct IdempotencyTransportTests {

    private func makeClient(tokenStore: any TokenStoring) -> URLSessionAPIClient {
        URLSessionAPIClient(
            baseURL: stubBaseURL,
            tokenStore: tokenStore,
            session: StubURLProtocol.session
        )
    }

    private func makeTokenStore() async throws -> TokenStore {
        let store = TokenStore(keychain: InMemoryKeychain())
        try await store.setTokens(
            TokenPair(accessToken: "mock-access-token", refreshToken: "mock-refresh-token")
        )
        return store
    }

    @Test("A profile write leaves with the key it was given")
    func theKeyIsSentAsTheIdempotencyKeyHeader() async throws {
        StubURLProtocol.script([.success(userJSON(name: "Ada"))])
        let tokenStore = try await makeTokenStore()
        let repository = LiveUserRepository(client: makeClient(tokenStore: tokenStore))
        let key = IdempotencyKey()

        let user = try await repository.updateProfile(name: "Ada", idempotencyKey: key)

        #expect(user.name == "Ada")
        let expected: [String?] = [key.rawValue]
        #expect(StubURLProtocol.recordedValues(of: IdempotencyKey.headerField) == expected)
    }

    @Test("A read leaves without one")
    func aReadCarriesNoIdempotencyHeader() async throws {
        StubURLProtocol.script([.success(userJSON(name: "Ada"))])
        let tokenStore = try await makeTokenStore()
        let repository = LiveUserRepository(client: makeClient(tokenStore: tokenStore))

        _ = try await repository.fetchCurrentUser()

        let expected: [String?] = [nil]
        #expect(StubURLProtocol.recordedValues(of: IdempotencyKey.headerField) == expected)
    }

    /// The duplicate no retry policy can see. `URLSessionAPIClient` re-sends the
    /// request itself after refreshing the token, so a 401 arriving *after* the
    /// server applied the write — an access token that expired between
    /// authorisation and the response being written — produces two deliveries
    /// of one edit from inside a single call.
    ///
    /// The assertion is on the two `PATCH`es, not the refresh in between: both
    /// must carry the key, and it must be the *same* key, or the second
    /// delivery is a second write as far as the server is concerned.
    @Test("The token-refresh retry re-sends the same key")
    func theRefreshRetryResendsTheSameKey() async throws {
        StubURLProtocol.script([
            .unauthorized,
            .success(refreshedTokensJSON),
            .success(userJSON(name: "Ada")),
        ])
        let tokenStore = try await makeTokenStore()
        let repository = LiveUserRepository(client: makeClient(tokenStore: tokenStore))
        let key = IdempotencyKey()

        let user = try await repository.updateProfile(name: "Ada", idempotencyKey: key)

        #expect(user.name == "Ada")
        let recorded = StubURLProtocol.recordedRequests
        #expect(recorded.count == 3)
        let methods: [String?] = ["PATCH", "POST", "PATCH"]
        #expect(recorded.map(\.httpMethod) == methods)
        // The refresh is a request of its own and carries no key; the two
        // deliveries of the edit carry one key between them.
        let keys: [String?] = [key.rawValue, nil, key.rawValue]
        #expect(StubURLProtocol.recordedValues(of: IdempotencyKey.headerField) == keys)
        // And the second delivery is the one that got the new token, which is
        // what makes it a *re-send* rather than the same request twice.
        let authorization = recorded[2].value(forHTTPHeaderField: "Authorization")
        #expect(authorization == "Bearer mock-access-token-2")
    }
}

// MARK: - Through the decorator chain

@Suite("Idempotency through the repository chain")
struct IdempotencyRepositoryTests {

    /// Two taps on Save are two intents and must not be collapsed into one by
    /// the server. The mint point being per-call is what guarantees it.
    @Test("Each edit gets its own key")
    func eachEditGetsItsOwnKey() async throws {
        let base = ScriptedRepository()

        _ = try await base.updateProfile(name: "First")
        _ = try await base.updateProfile(name: "Second")

        #expect(base.updateKeys.count == 2)
        #expect(base.updateKeys[0] != base.updateKeys[1])
    }

    /// The property the widened write policy is built on. Three deliveries, one
    /// key: a server that honours the header answers the second and third from
    /// the record of the first instead of applying the edit again.
    @Test("Every attempt of one edit carries the same key")
    func everyAttemptOfOneEditCarriesTheSameKey() async throws {
        let base = ScriptedRepository()
        base.updateFailures = [serverAnswered, deliveryUnknown]
        let repository = RetryingUserRepository(base: base, sleep: SleepLog().sleep)

        _ = try await repository.updateProfile(name: "Retried")

        #expect(base.updateKeys.count == 3)
        #expect(Set(base.updateKeys).count == 1)
    }

    /// The same claim against the composition the app actually runs, because
    /// forwarding is the kind of thing each decorator gets right individually
    /// and one of them stops doing on a refactor. A cache that re-minted, or a
    /// telemetry wrapper that dropped the parameter, would show up here as
    /// three keys for one edit.
    @Test("The key survives every decorator between the caller and the client")
    func theKeySurvivesTheWholeDecoratorChain() async throws {
        let base = ScriptedRepository()
        base.updateFailures = [serverAnswered, serverAnswered]
        let repository = TelemetryUserRepository(
            base: CachingUserRepository(
                base: RetryingUserRepository(base: base, sleep: SleepLog().sleep)
            ),
            telemetry: RecordingRepositoryTelemetry()
        )

        _ = try await repository.updateProfile(name: "Edited")

        #expect(base.updateCount == 3)
        #expect(Set(base.updateKeys).count == 1)
    }

    /// A read has no key to forward, and nothing along the chain should invent
    /// one for it — the endpoint refuses a key on a `GET`, so a repository that
    /// tried would trap rather than merely waste a header.
    @Test("A read still takes the read policy and no key")
    func readsAreUnaffected() async throws {
        let base = ScriptedRepository()
        base.fetchFailures = [serverAnswered]
        let repository = RetryingUserRepository(base: base, sleep: SleepLog().sleep)

        _ = try await repository.fetchCurrentUser()

        #expect(base.fetchCount == 2)
        #expect(base.updateKeys.isEmpty)
    }
}
