import Foundation

// MARK: - Protocol

/// Abstracts all user-profile data operations.
/// Concrete types are injected at the call site; tests supply `MockUserRepository`.
protocol UserRepository: Sendable {
    func fetchCurrentUser() async throws -> User
    func updateProfile(name: String) async throws -> User
    func deleteAccount() async throws
}

// MARK: - Errors

enum UserRepositoryError: LocalizedError, Equatable {
    case notFound
    case unauthorized
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .notFound: "User not found."
        case .unauthorized: "You must be signed in."
        case .networkUnavailable: "No network connection."
        }
    }
}

// MARK: - Live implementation (stub — real URLSession client added in Phase 3)

struct LiveUserRepository: UserRepository {
    func fetchCurrentUser() async throws -> User {
        try await Task.sleep(for: .milliseconds(500))
        return User(
            id: UUID(),
            email: "user@example.com",
            name: "Demo User"
        )
    }

    func updateProfile(name: String) async throws -> User {
        try await Task.sleep(for: .milliseconds(300))
        return User(
            id: UUID(),
            email: "user@example.com",
            name: name
        )
    }

    func deleteAccount() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }
}

// MARK: - Mock for previews & tests

@MainActor
final class MockUserRepository: UserRepository {
    var stubbedUser = User(id: UUID(), email: "mock@example.com", name: "Mock User")
    var shouldThrow = false
    var stubbedError: UserRepositoryError = .networkUnavailable
    private(set) var fetchCallCount = 0
    private(set) var updateCallCount = 0
    private(set) var deleteCallCount = 0

    func fetchCurrentUser() async throws -> User {
        fetchCallCount += 1
        if shouldThrow { throw stubbedError }
        return stubbedUser
    }

    func updateProfile(name: String) async throws -> User {
        updateCallCount += 1
        if shouldThrow { throw stubbedError }
        stubbedUser = User(id: stubbedUser.id, email: stubbedUser.email, name: name)
        return stubbedUser
    }

    func deleteAccount() async throws {
        deleteCallCount += 1
        if shouldThrow { throw stubbedError }
    }
}
