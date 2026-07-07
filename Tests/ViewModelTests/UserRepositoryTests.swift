import Testing
@testable import BoilerplateiOSSwift

@MainActor
struct UserRepositoryTests {

    // MARK: - fetchCurrentUser

    @Test func fetchCurrentUserReturnsStubUser() async throws {
        let repo = MockUserRepository()
        let user = try await repo.fetchCurrentUser()
        #expect(user.email == "mock@example.com")
        #expect(user.name == "Mock User")
    }

    @Test func fetchCurrentUserIncrementsFetchCallCount() async throws {
        let repo = MockUserRepository()
        _ = try await repo.fetchCurrentUser()
        _ = try await repo.fetchCurrentUser()
        #expect(repo.fetchCallCount == 2)
    }

    @Test func fetchCurrentUserPropagatesError() async {
        let repo = MockUserRepository()
        repo.shouldThrow = true
        repo.stubbedError = .notFound
        var caught: UserRepositoryError?
        do {
            _ = try await repo.fetchCurrentUser()
        } catch let error as UserRepositoryError {
            caught = error
        } catch {}
        #expect(caught == .notFound)
        #expect(repo.fetchCallCount == 1)
    }

    // MARK: - updateProfile

    @Test func updateProfileReturnsUserWithNewName() async throws {
        let repo = MockUserRepository()
        let updated = try await repo.updateProfile(name: "New Name")
        #expect(updated.name == "New Name")
    }

    @Test func updateProfileMutatesStubbedUser() async throws {
        let repo = MockUserRepository()
        _ = try await repo.updateProfile(name: "Changed")
        #expect(repo.stubbedUser.name == "Changed")
    }

    @Test func updateProfileIncrementsUpdateCallCount() async throws {
        let repo = MockUserRepository()
        _ = try await repo.updateProfile(name: "A")
        _ = try await repo.updateProfile(name: "B")
        #expect(repo.updateCallCount == 2)
    }

    @Test func updateProfilePreservesUserIdentity() async throws {
        let repo = MockUserRepository()
        let originalID = repo.stubbedUser.id
        let updated = try await repo.updateProfile(name: "Renamed")
        #expect(updated.id == originalID)
    }

    @Test func updateProfilePropagatesError() async {
        let repo = MockUserRepository()
        repo.shouldThrow = true
        repo.stubbedError = .unauthorized
        var caught: UserRepositoryError?
        do {
            _ = try await repo.updateProfile(name: "Fails")
        } catch let error as UserRepositoryError {
            caught = error
        } catch {}
        #expect(caught == .unauthorized)
    }

    // MARK: - deleteAccount

    @Test func deleteAccountIncrementsDeleteCallCount() async throws {
        let repo = MockUserRepository()
        try await repo.deleteAccount()
        try await repo.deleteAccount()
        #expect(repo.deleteCallCount == 2)
    }

    @Test func deleteAccountPropagatesError() async {
        let repo = MockUserRepository()
        repo.shouldThrow = true
        repo.stubbedError = .networkUnavailable
        var caught: UserRepositoryError?
        do {
            try await repo.deleteAccount()
        } catch let error as UserRepositoryError {
            caught = error
        } catch {}
        #expect(caught == .networkUnavailable)
    }

    // MARK: - UserRepositoryError descriptions

    @Test func errorDescriptionsAreNonEmpty() {
        let errors: [UserRepositoryError] = [.notFound, .unauthorized, .networkUnavailable]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }
}
