import SwiftData
import Foundation

/// SwiftData persistent model for the authenticated user.
/// Mapped to the `User` domain struct via `toDomainUser()` and `User.toEntity()`.
@Model
final class UserEntity {
    // `id` deliberately carries no `@Attribute(.unique)`. SwiftData does not support
    // unique constraints on an in-memory store, and it does not report that by
    // throwing — it traps, on every operation against the container, `insert` and
    // `fetch` alike. `PersistenceController.makeInMemoryContainer()` is what previews
    // and the whole persistence test suite run on, so the constraint made the entity
    // unusable everywhere it was actually exercised.
    //
    // Little is given up. `id` is a `UUID` the app assigns before insert, never a value
    // the store derives, and nothing here relies on the upsert-on-conflict behaviour
    // `.unique` provides: `save(user:)` inserts, and `update(user:)` looks the row up
    // first. Uniqueness is enforced by where the identifier comes from.
    var id: UUID
    var email: String
    var name: String
    var avatarURL: URL?
    var createdAt: Date?
    var updatedAt: Date?

    init(
        id: UUID,
        email: String,
        name: String,
        avatarURL: URL? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.email = email
        self.name = name
        self.avatarURL = avatarURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func toDomainUser() -> User {
        User(
            id: id,
            email: email,
            name: name,
            avatarURL: avatarURL,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

extension User {
    func toEntity() -> UserEntity {
        UserEntity(
            id: id,
            email: email,
            name: name,
            avatarURL: avatarURL,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
