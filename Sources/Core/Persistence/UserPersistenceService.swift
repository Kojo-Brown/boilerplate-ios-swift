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

    func fetchCurrentUser() throws -> User? {
        let descriptor = FetchDescriptor<UserEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor).first?.toDomainUser()
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
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            .first
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
