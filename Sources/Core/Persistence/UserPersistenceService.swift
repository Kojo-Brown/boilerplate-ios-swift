import SwiftData
import Foundation

// MARK: - Protocol

/// Typed CRUD surface over the SwiftData `UserEntity` model.
/// The `async` qualifier on each method lets non-`@MainActor` callers
/// cross the actor boundary with a plain `await`.
protocol UserPersistenceService: Sendable {
    func save(user: User) async throws
    func fetchCurrentUser() async throws -> User?
    func update(user: User) async throws
    func delete(userId: UUID) async throws
    func deleteAll() async throws
}

// MARK: - Live implementation

/// SwiftData-backed implementation. Confined to `@MainActor` because `ModelContext`
/// is not `Sendable` and must be accessed from a single concurrency domain.
@MainActor
final class SwiftDataUserPersistenceService: UserPersistenceService {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func save(user: User) throws {
        context.insert(user.toEntity())
        try context.save()
    }

    /// Returns the most recently created stored user, or `nil` when the store is empty.
    ///
    /// The sort is done in memory rather than by the store. `FetchDescriptor(sortBy:)`
    /// with a `SortDescriptor` over an **optional** key path — `createdAt` is `Date?` —
    /// traps inside SwiftData while executing the fetch (`EXC_BREAKPOINT`, taking the
    /// whole test process with it, not just the failing test). Making `createdAt`
    /// non-optional would fix the sort by breaking the model: the API genuinely may
    /// omit the field.
    ///
    /// Sorting here is not the compromise it looks like. This store holds the signed-in
    /// user, so the fetch is over a handful of rows at most, and `nil` has to be ordered
    /// explicitly anyway — treating it as oldest, which the database sort could not
    /// express. `MockUserPersistenceService` already ordered it exactly this way; the
    /// two implementations now agree, where before only the mock was reachable.
    func fetchCurrentUser() throws -> User? {
        try context.fetch(FetchDescriptor<UserEntity>())
            .max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }?
            .toDomainUser()
    }

    func update(user: User) throws {
        let id = user.id
        var descriptor = FetchDescriptor<UserEntity>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let entity = try context.fetch(descriptor).first else {
            throw PersistenceError.userNotFound
        }
        entity.name = user.name
        entity.avatarURL = user.avatarURL
        entity.updatedAt = user.updatedAt
        try context.save()
    }

    func delete(userId: UUID) throws {
        let id = userId
        var descriptor = FetchDescriptor<UserEntity>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let entity = try context.fetch(descriptor).first else {
            throw PersistenceError.userNotFound
        }
        context.delete(entity)
        try context.save()
    }

    func deleteAll() throws {
        let all = try context.fetch(FetchDescriptor<UserEntity>())
        for entity in all { context.delete(entity) }
        try context.save()
    }
}

// MARK: - Mock for previews and tests

@MainActor
final class MockUserPersistenceService: UserPersistenceService {
    var storage: [UUID: User] = [:]
    var shouldThrow = false
    var stubbedError: PersistenceError = .userNotFound

    private(set) var saveCallCount = 0
    private(set) var fetchCallCount = 0
    private(set) var updateCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var deleteAllCallCount = 0

    func save(user: User) throws {
        saveCallCount += 1
        if shouldThrow { throw stubbedError }
        storage[user.id] = user
    }

    func fetchCurrentUser() throws -> User? {
        fetchCallCount += 1
        if shouldThrow { throw stubbedError }
        return storage.values
            .max { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    func update(user: User) throws {
        updateCallCount += 1
        if shouldThrow { throw stubbedError }
        guard storage[user.id] != nil else { throw PersistenceError.userNotFound }
        storage[user.id] = user
    }

    func delete(userId: UUID) throws {
        deleteCallCount += 1
        if shouldThrow { throw stubbedError }
        guard storage[userId] != nil else { throw PersistenceError.userNotFound }
        storage.removeValue(forKey: userId)
    }

    func deleteAll() throws {
        deleteAllCallCount += 1
        if shouldThrow { throw stubbedError }
        storage.removeAll()
    }
}
