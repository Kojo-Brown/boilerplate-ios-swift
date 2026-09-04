import Core
import Foundation

// MARK: - Protocol

/// Abstracts all user-profile data operations.
/// Concrete types are injected at the call site; tests supply `MockUserRepository`.
///
/// ## Why the write takes a key and the other two do not
///
/// `updateProfile` is the only operation here whose repetition is not free.
/// `fetchCurrentUser` is a `GET`, and `deleteAccount` is a `DELETE` against a
/// resource that either exists or does not — repeating either converges on the
/// same server state, which is what makes `RetryingUserRepository` willing to
/// retry them through any transient failure. A key on `DELETE` would change the
/// *status code* a duplicate sees, from a 404 to the original 204; it would not
/// change the state, and that is not enough to buy a parameter on the protocol.
///
/// `updateProfile` is a `PATCH`, where a lost response leaves the client unable
/// to say whether the write happened. The key is how it stops having to guess —
/// see ``IdempotencyKey`` and `docs/idempotency.md`.
package protocol UserRepository: Sendable {
    func fetchCurrentUser() async throws -> User

    /// - Parameter idempotencyKey: Identifies the logical edit, not this
    ///   delivery of it. A decorator that retries **must** pass the key it was
    ///   given to each attempt rather than minting one per attempt; a key that
    ///   changes between attempts is indistinguishable, to the server, from two
    ///   people editing the profile at once.
    func updateProfile(name: String, idempotencyKey: IdempotencyKey) async throws -> User

    func deleteAccount() async throws
}

extension UserRepository {

    /// One profile edit, with a key minted for it.
    ///
    /// This is what a caller with an intent calls. Each call is a *new* intent
    /// and so gets a new key: a person who taps Save twice has asked for two
    /// writes and should get two, while a transport failure retried underneath
    /// this call is one write and gets one key, because the retry happens below
    /// here with the key already fixed.
    ///
    /// It is an extension rather than a protocol requirement on purpose. A
    /// conformer overriding it could quietly re-mint a key mid-chain — the one
    /// mistake that makes the whole mechanism decorative — so the mint point is
    /// deliberately not a customisation point.
    package func updateProfile(name: String) async throws -> User {
        try await updateProfile(name: name, idempotencyKey: IdempotencyKey())
    }
}

// MARK: - Errors

package enum UserRepositoryError: LocalizedError, Equatable {
    case notFound
    case unauthorized
    case networkUnavailable

    package var errorDescription: String? {
        switch self {
        case .notFound: "User not found."
        case .unauthorized: "You must be signed in."
        case .networkUnavailable: "No network connection."
        }
    }
}

// MARK: - Live implementation

package struct LiveUserRepository: UserRepository {
    private let client: any APIClient

    package init(client: any APIClient) {
        self.client = client
    }

    package func fetchCurrentUser() async throws -> User {
        try await client.send(APIEndpoint.get("/users/me"))
    }

    package func updateProfile(name: String, idempotencyKey: IdempotencyKey) async throws -> User {
        try await client.send(
            APIEndpoint.patch(
                "/users/me",
                body: UpdateProfileRequest(name: name),
                idempotencyKey: idempotencyKey
            )
        )
    }

    package func deleteAccount() async throws {
        let _: EmptyResponse = try await client.send(APIEndpoint.delete("/users/me"))
    }
}

// MARK: - Mock for previews & tests

@MainActor
package final class MockUserRepository: UserRepository {
    package init() {}

    package var stubbedUser = User(id: UUID(), email: "mock@example.com", name: "Mock User")
    package var shouldThrow = false
    package var stubbedError: UserRepositoryError = .networkUnavailable
    private(set) var fetchCallCount = 0
    private(set) var updateCallCount = 0
    private(set) var deleteCallCount = 0

    /// The key on every `updateProfile` this double was asked to perform, in
    /// order, including the ones it threw for.
    ///
    /// Recorded rather than merely counted because the count cannot express the
    /// property that matters: two deliveries of one edit are two entries with
    /// the *same* key, and two edits are two entries with different ones. A
    /// double that only counted calls would pass identically either way.
    private(set) var updateKeys: [IdempotencyKey] = []

    package func fetchCurrentUser() async throws -> User {
        fetchCallCount += 1
        if shouldThrow { throw stubbedError }
        return stubbedUser
    }

    package func updateProfile(name: String, idempotencyKey: IdempotencyKey) async throws -> User {
        updateCallCount += 1
        updateKeys.append(idempotencyKey)
        if shouldThrow { throw stubbedError }
        // A derivation rather than a rebuild: the previous spelling passed `id`
        // and `email` through by hand and let the memberwise initialiser default
        // the avatar and both timestamps back to `nil`, so a double sets a
        // profile up and then watches the mock throw half of it away.
        stubbedUser = stubbedUser.with(name: .set(name))
        return stubbedUser
    }

    package func deleteAccount() async throws {
        deleteCallCount += 1
        if shouldThrow { throw stubbedError }
    }
}
