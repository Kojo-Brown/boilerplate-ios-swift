import Core
import Foundation

// MARK: - Protocol

/// Abstracts all user-profile data operations.
/// Concrete types are injected at the call site; tests supply `MockUserRepository`.
package protocol UserRepository: Sendable {
    func fetchCurrentUser() async throws -> User
    func updateProfile(name: String) async throws -> User
    func deleteAccount() async throws
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

    package func updateProfile(name: String) async throws -> User {
        try await client.send(
            APIEndpoint.patch("/users/me", body: UpdateProfileRequest(name: name))
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

    package func fetchCurrentUser() async throws -> User {
        fetchCallCount += 1
        if shouldThrow { throw stubbedError }
        return stubbedUser
    }

    package func updateProfile(name: String) async throws -> User {
        updateCallCount += 1
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
