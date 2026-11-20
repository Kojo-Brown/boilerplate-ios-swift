import Foundation
import Testing
@testable import Core
@testable import Networking

// MARK: - The two implementations under contract

/// Which `UserRepository` a contract case is running against.
///
/// The point of the enum is that the case bodies below cannot tell. A contract
/// case is one sentence about `UserRepository`, run twice; a case that needs to
/// know which side it has is not a contract case and belongs in the divergence
/// section at the end of this file.
enum RepositoryUnderContract: String, CaseIterable, Sendable {
    /// `LiveUserRepository` over a real `URLSessionAPIClient` over a real
    /// `URLSession`, answered by `FakeUserAPI`. Everything between the
    /// repository and the socket is the shipping code.
    case liveOverFakeServer

    /// The hand-written double from `Sources/`, which is what almost every
    /// other suite in this bundle is actually testing against.
    case handWrittenDouble
}

// MARK: - Fixtures

/// Whole seconds on purpose.
///
/// `JSONEncoder.apiEncoder` uses `.iso8601`, which has no fractional-second
/// component, so a `Date()` would come back from the live stack rounded and the
/// field-preservation case would fail for a reason that has nothing to do with
/// either implementation.
private let seedCreatedAt = Date(timeIntervalSince1970: 1_700_000_000)
private let seedUpdatedAt = Date(timeIntervalSince1970: 1_700_000_600)

private func makeSeedUser() -> User {
    User(
        email: "contract@example.invalid",
        name: "Original Name",
        avatarURL: URL(string: "https://avatars.example.invalid/contract.png"),
        createdAt: seedCreatedAt,
        updatedAt: seedUpdatedAt,
        version: 7
    )
}

@MainActor
private func makeLiveRepository(
    seededWith user: User?,
    deleteAnswer: FakeUserAPI.DeleteAnswer = .okEmptyObject
) -> LiveUserRepository {
    FakeUserAPI.reset(user: user, deleteAnswer: deleteAnswer)
    return LiveUserRepository(
        client: URLSessionAPIClient(
            baseURL: FakeUserAPI.baseURL,
            tokenStore: InMemoryTokenStore(
                pair: TokenPair(accessToken: "mock-access-token", refreshToken: "mock-refresh-token")
            ),
            session: FakeUserAPI.session,
            attestor: UnattestedRequests()
        )
    )
}

@MainActor
private func makeDouble(seededWith user: User) -> MockUserRepository {
    let double = MockUserRepository()
    double.stubbedUser = user
    return double
}

// MARK: - The contract

/// The contract `UserRepository` states, run against both implementations, and
/// the pins for what the two do not share.
///
/// `docs/solid.md` put the problem this closes in one sentence: the doubles here
/// "are two independent readings of a contract that is written down nowhere".
/// Finding 3 was one divergence somebody noticed, repaired by hand, and pinned
/// with a single assertion about a single method. The cases below are the
/// contract itself — each runs twice, so a double that stops agreeing fails
/// rather than waiting to be noticed.
///
/// Both halves are in **one** suite rather than two, and that is not tidiness.
/// `FakeUserAPI` keeps its record in a static, because `URLSession` builds the
/// protocol instance and there is nothing per-test to configure; `.serialized`
/// orders the cases within a suite, and Swift Testing runs *suites* in parallel
/// with each other. Two serialized suites sharing one server would interleave on
/// a schedule that changes with the runner's core count — which is the mistake
/// `AttestationStubURLProtocol` exists to avoid having made twice.
///
/// `@MainActor` because `MockUserRepository` is, which is `docs/solid.md`
/// finding 5 and is left standing here: the repair it recommends is a change to
/// the double's isolation, not to this contract, and
/// `liveRepositoryIsNotActorIsolated` is the pin that keeps it honest.
@Suite("UserRepository contract", .serialized)
@MainActor
struct UserRepositoryContractTests {

    private func repository(
        _ kind: RepositoryUnderContract,
        seededWith user: User
    ) -> any UserRepository {
        switch kind {
        case .liveOverFakeServer: return makeLiveRepository(seededWith: user)
        case .handWrittenDouble: return makeDouble(seededWith: user)
        }
    }

    @Test("A fetch returns the stored profile", arguments: RepositoryUnderContract.allCases)
    func fetchReturnsTheStoredProfile(_ kind: RepositoryUnderContract) async throws {
        let seed = makeSeedUser()
        let subject = repository(kind, seededWith: seed)

        let fetched = try await subject.fetchCurrentUser()

        #expect(fetched.id == seed.id)
        #expect(fetched.email == seed.email)
        #expect(fetched.name == seed.name)
    }

    /// Every mapped field, not the three a reader assumes a profile has.
    ///
    /// The live side round-trips through JSON and the double does not, so this
    /// is the case that fails if the wire representation drops a field — which
    /// is a defect in the *live* implementation that a suite using only the
    /// double could never see.
    @Test("A fetch preserves every field of the profile", arguments: RepositoryUnderContract.allCases)
    func fetchPreservesEveryField(_ kind: RepositoryUnderContract) async throws {
        let seed = makeSeedUser()
        let subject = repository(kind, seededWith: seed)

        let fetched = try await subject.fetchCurrentUser()

        #expect(fetched.avatarURL == seed.avatarURL)
        #expect(fetched.createdAt == seed.createdAt)
        #expect(fetched.updatedAt == seed.updatedAt)
        #expect(fetched.version == seed.version)
    }

    @Test("An edit returns the name it was asked for", arguments: RepositoryUnderContract.allCases)
    func updateReturnsTheRequestedName(_ kind: RepositoryUnderContract) async throws {
        let subject = repository(kind, seededWith: makeSeedUser())

        let updated = try await subject.updateProfile(name: "Renamed")

        #expect(updated.name == "Renamed")
    }

    /// The case `StubURLProtocol` cannot express, and the reason `FakeUserAPI`
    /// holds a record rather than a queue of scripted answers.
    @Test("An edit is visible to the next fetch", arguments: RepositoryUnderContract.allCases)
    func updateIsVisibleToTheNextFetch(_ kind: RepositoryUnderContract) async throws {
        let subject = repository(kind, seededWith: makeSeedUser())

        _ = try await subject.updateProfile(name: "Renamed")
        let fetched = try await subject.fetchCurrentUser()

        #expect(fetched.name == "Renamed")
    }

    /// An edit to the name is an edit to the name.
    ///
    /// `MockUserRepository.updateProfile` used to rebuild the user from `id` and
    /// `email`, which silently dropped the avatar and both timestamps because
    /// the memberwise initialiser defaults them to `nil`. That was repaired when
    /// `User.with(_:)` arrived; this is what stops it coming back, on both
    /// sides.
    @Test("An edit leaves the fields it was not asked about", arguments: RepositoryUnderContract.allCases)
    func updateLeavesUnrelatedFieldsAlone(_ kind: RepositoryUnderContract) async throws {
        let seed = makeSeedUser()
        let subject = repository(kind, seededWith: seed)

        let updated = try await subject.updateProfile(name: "Renamed")

        #expect(updated.id == seed.id)
        #expect(updated.email == seed.email)
        #expect(updated.avatarURL == seed.avatarURL)
        #expect(updated.createdAt == seed.createdAt)
    }

    @Test("Deleting the account succeeds", arguments: RepositoryUnderContract.allCases)
    func deleteAccountSucceeds(_ kind: RepositoryUnderContract) async throws {
        let subject = repository(kind, seededWith: makeSeedUser())

        try await subject.deleteAccount()
    }

    // MARK: - What the two do not share

    // Each case below asserts a divergence, in the idiom
    // `SolidSubstitutabilityTests` established: it **fails when the divergence
    // is repaired**, so the repair lands together with the edit to
    // `docs/test-doubles.md` that stops describing it. Reading them as ordinary
    // tests gets them backwards — none is a claim that the current behaviour is
    // right. Every one of them is listed in `Tools/assert-test-doubles.py`, in
    // both directions, so a divergence cannot be dropped silently and a pin
    // cannot outlive the thing it pins.

    /// The double has no state for a delete to remove, so a suite that drives a
    /// delete-account flow through it can never observe that the account is
    /// gone — every assertion after the delete is answered by the profile the
    /// double still holds.
    ///
    /// Repairing it means giving `MockUserRepository` a deleted state and a
    /// failure to throw from `fetchCurrentUser` afterwards, which runs straight
    /// into the error-vocabulary divergence (`docs/solid.md` finding 4): the
    /// live stack throws `APIError.httpError(statusCode: 404, …)` and the
    /// double's vocabulary has no case for it.
    @Test("A delete leaves the double still answering fetches")
    func deleteLeavesTheDoubleAnsweringFetches() async throws {
        let double = MockUserRepository()
        try await double.deleteAccount()

        let afterDelete = try await double.fetchCurrentUser()
        #expect(afterDelete.email == "mock@example.com")

        let live = makeLiveRepository(seededWith: makeSeedUser())
        try await live.deleteAccount()

        await #expect(throws: APIError.self) {
            _ = try await live.fetchCurrentUser()
        }
    }

    /// `204 No Content` is the correct answer to a `DELETE`, and
    /// `LiveUserRepository.deleteAccount()` fails against it.
    ///
    /// `deleteAccount` asks for `EmptyResponse`, `URLSessionAPIClient.send`
    /// decodes every response body, and an empty body is not valid JSON — so a
    /// correct server turns a request that succeeded into
    /// `APIError.decodingFailed`. The behaviour is known: `APICrashReportUploader`
    /// maps `decodingFailed` to `accepted` precisely because of it, and says so.
    /// What was not known is that nothing could see it here, because the only
    /// double for this seam returns from `deleteAccount` with no body to decode.
    ///
    /// Not repaired in this item. The fix is a transport that can be asked to
    /// discard a body rather than decode an empty one, which is a change to
    /// `APIClient`'s protocol surface and belongs to the transport. This is the
    /// pin that keeps it from being forgotten.
    @Test("A no-content delete fails, and only against the live stack")
    func aNoContentDeleteFailsOnlyAgainstTheLiveStack() async throws {
        let live = makeLiveRepository(seededWith: makeSeedUser(), deleteAnswer: .noContent)

        do {
            try await live.deleteAccount()
            Issue.record("a 204 with an empty body should not have decoded")
        } catch let error as APIError {
            guard case .decodingFailed = error else {
                Issue.record("expected .decodingFailed, got \(error)")
                return
            }
        }

        // The same call, through the double, reports success.
        let double = MockUserRepository()
        try await double.deleteAccount()
    }

    /// The server owns the revision counter, and the double cannot.
    ///
    /// `User.version` is what `UserMergePolicy` orders two copies of a profile
    /// by, and it advances per accepted write — a fact about the server. The
    /// live stack returns the response body, so an edit comes back with a higher
    /// version; the double derives its answer locally from the value it already
    /// held, so an edit comes back with the same one. A merge-policy scenario
    /// driven through the double therefore never sees a revision move.
    ///
    /// Not repairable by making the double more faithful: inventing an increment
    /// would be the double asserting something about a server nobody has
    /// configured. It is a limit of the seam, recorded rather than buried — a
    /// test about revision ordering has to drive the fake server.
    @Test("An edit advances the revision only against the live stack")
    func anEditAdvancesTheRevisionOnlyLive() async throws {
        let seed = makeSeedUser()

        let live = makeLiveRepository(seededWith: seed)
        let liveUpdated = try await live.updateProfile(name: "Renamed")
        #expect(liveUpdated.version == (seed.version ?? 0) + 1)

        let double = makeDouble(seededWith: seed)
        let doubleUpdated = try await double.updateProfile(name: "Renamed")
        #expect(doubleUpdated.version == seed.version)
    }

    /// One edit redelivered is one write — the property the `Idempotency-Key`
    /// exists for — and the two implementations record it somewhere a shared
    /// case cannot reach.
    ///
    /// The live side's evidence is on the server: a second delivery of a key it
    /// has already accepted is answered from the ledger and not applied again.
    /// The double's evidence is `updateKeys`, a list inside the double. Both are
    /// asserted here, together, because the pair is the claim —
    /// `docs/idempotency.md` has the rest.
    @Test("A redelivered edit is one write on the server and two keys in the double")
    func aRedeliveredEditIsOneWrite() async throws {
        let seed = makeSeedUser()
        let key = IdempotencyKey()

        let live = makeLiveRepository(seededWith: seed)
        _ = try await live.updateProfile(name: "Renamed", idempotencyKey: key)
        _ = try await live.updateProfile(name: "Renamed", idempotencyKey: key)

        let stored = try #require(FakeUserAPI.storedUser)
        #expect(stored.version == (seed.version ?? 0) + 1)
        #expect(FakeUserAPI.calls.count == 2)

        let double = makeDouble(seededWith: seed)
        _ = try await double.updateProfile(name: "Renamed", idempotencyKey: key)
        _ = try await double.updateProfile(name: "Renamed", idempotencyKey: key)
        #expect(double.updateKeys == [key, key])
    }
}
