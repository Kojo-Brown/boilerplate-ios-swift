import Foundation
import Testing
import SwiftData
@testable import BoilerplateiOSSwift

// MARK: - SwiftDataUserPersistenceService integration tests

/// The container is held for the lifetime of each test, and that is the point.
///
/// `SwiftDataUserPersistenceService` stores only a `ModelContext`, and a context does
/// not keep its `ModelContainer` alive — the container owns the context, not the other
/// way round. This suite used to build the container inside a helper and return only
/// `container.mainContext`, so the container was deallocated the moment the helper
/// returned and every test ran against an orphaned context. SwiftData reports that by
/// trapping (`EXC_BREAKPOINT`, no `asi` message) rather than throwing, which kills the
/// whole test process instead of one test.
///
/// That is why *every* operation trapped — `fetch` and `insert` alike, at different
/// addresses — and why only this suite ever crashed: it is the only one that builds a
/// container. Holding it in a stored property fixes the lifetime. Swift Testing makes
/// a fresh instance of the suite for each test, so this is still one container per
/// test and the isolation between tests is unchanged.
///
/// `.serialized` is retained for now but is **not** known to be needed: it was added
/// on the theory that concurrent containers were the cause, and it did not stop the
/// crash. Removing it is the next thing to try once this suite is green — one variable
/// at a time, since CI is the only oracle here.
@Suite(.serialized)
@MainActor
struct UserPersistenceTests {

    private let container: ModelContainer
    private let service: SwiftDataUserPersistenceService

    init() throws {
        container = try PersistenceController.makeInMemoryContainer()
        service = SwiftDataUserPersistenceService(context: container.mainContext)
    }

    // MARK: - save / fetchCurrentUser

    @Test func saveAndFetchReturnsUser() throws {
        let user = User(email: "save@test.com", name: "Save Test")
        try service.save(user: user)
        let fetched = try service.fetchCurrentUser()
        #expect(fetched?.id == user.id)
        #expect(fetched?.email == "save@test.com")
        #expect(fetched?.name == "Save Test")
    }

    @Test func fetchCurrentUserReturnsNilWhenEmpty() throws {
        #expect(try service.fetchCurrentUser() == nil)
    }

    // MARK: - update

    @Test func updateChangesName() throws {
        let user = User(email: "update@test.com", name: "Before")
        try service.save(user: user)
        let modified = User(id: user.id, email: user.email, name: "After")
        try service.update(user: modified)
        let fetched = try service.fetchCurrentUser()
        #expect(fetched?.name == "After")
    }

    @Test func updateThrowsForMissingUser() throws {
        let ghost = User(email: "ghost@test.com", name: "Ghost")
        var caught: PersistenceError?
        do {
            try service.update(user: ghost)
        } catch let error as PersistenceError {
            caught = error
        } catch {}
        #expect(caught == .userNotFound)
    }

    // MARK: - delete

    @Test func deleteRemovesUser() throws {
        let user = User(email: "delete@test.com", name: "Delete Me")
        try service.save(user: user)
        try service.delete(userId: user.id)
        #expect(try service.fetchCurrentUser() == nil)
    }

    @Test func deleteThrowsForMissingUser() throws {
        var caught: PersistenceError?
        do {
            try service.delete(userId: UUID())
        } catch let error as PersistenceError {
            caught = error
        } catch {}
        #expect(caught == .userNotFound)
    }

    // MARK: - deleteAll

    @Test func deleteAllClearsAllUsers() throws {
        try service.save(user: User(email: "a@test.com", name: "A"))
        try service.save(user: User(email: "b@test.com", name: "B"))
        try service.deleteAll()
        #expect(try service.fetchCurrentUser() == nil)
    }

    // MARK: - domain conversion

    @Test func userEntityRoundTrip() {
        let original = User(
            id: UUID(),
            email: "rt@test.com",
            name: "Round Trip",
            avatarURL: nil,
            createdAt: nil,
            updatedAt: nil
        )
        let entity = original.toEntity()
        let restored = entity.toDomainUser()
        #expect(restored == original)
    }

    // MARK: - PersistenceError

    @Test func persistenceErrorDescriptionIsNonEmpty() {
        #expect(PersistenceError.userNotFound.errorDescription?.isEmpty == false)
    }
}

// MARK: - MockUserPersistenceService tests

@MainActor
struct MockUserPersistenceServiceTests {

    @Test func saveIncrementsSaveCount() throws {
        let service = MockUserPersistenceService()
        try service.save(user: User(email: "a@b.com", name: "A"))
        #expect(service.saveCallCount == 1)
    }

    @Test func fetchReturnsNilWhenEmpty() throws {
        let service = MockUserPersistenceService()
        #expect(try service.fetchCurrentUser() == nil)
        #expect(service.fetchCallCount == 1)
    }

    @Test func fetchReturnsLatestSavedByCreatedAt() throws {
        let service = MockUserPersistenceService()
        let older = User(email: "a@b.com", name: "Older", createdAt: Date(timeIntervalSince1970: 1_000))
        let newer = User(email: "b@c.com", name: "Newer", createdAt: Date(timeIntervalSince1970: 2_000))
        try service.save(user: older)
        try service.save(user: newer)
        let result = try service.fetchCurrentUser()
        #expect(result?.email == "b@c.com")
    }

    @Test func updateModifiesStoredUser() throws {
        let service = MockUserPersistenceService()
        let user = User(email: "x@y.com", name: "Original")
        try service.save(user: user)
        let modified = User(id: user.id, email: user.email, name: "Modified")
        try service.update(user: modified)
        #expect(service.storage[user.id]?.name == "Modified")
        #expect(service.updateCallCount == 1)
    }

    @Test func updateThrowsForMissingUser() throws {
        let service = MockUserPersistenceService()
        var caught: PersistenceError?
        do {
            try service.update(user: User(email: "missing@b.com", name: "Missing"))
        } catch let error as PersistenceError {
            caught = error
        } catch {}
        #expect(caught == .userNotFound)
    }

    @Test func deleteRemovesFromStorage() throws {
        let service = MockUserPersistenceService()
        let user = User(email: "del@b.com", name: "Del")
        try service.save(user: user)
        try service.delete(userId: user.id)
        #expect(service.storage.isEmpty)
        #expect(service.deleteCallCount == 1)
    }

    @Test func deleteAllClearsStorage() throws {
        let service = MockUserPersistenceService()
        try service.save(user: User(email: "a@b.com", name: "A"))
        try service.save(user: User(email: "c@d.com", name: "C"))
        try service.deleteAll()
        #expect(service.storage.isEmpty)
        #expect(service.deleteAllCallCount == 1)
    }

    @Test func shouldThrowPropagatesSaveError() throws {
        let service = MockUserPersistenceService()
        service.shouldThrow = true
        service.stubbedError = .userNotFound
        var caught: PersistenceError?
        do {
            try service.save(user: User(email: "a@b.com", name: "A"))
        } catch let error as PersistenceError {
            caught = error
        } catch {}
        #expect(caught == .userNotFound)
    }

    @Test func shouldThrowPropagatesFetchError() throws {
        let service = MockUserPersistenceService()
        service.shouldThrow = true
        var caught: PersistenceError?
        do {
            _ = try service.fetchCurrentUser()
        } catch let error as PersistenceError {
            caught = error
        } catch {}
        #expect(caught == .userNotFound)
    }
}
