import SwiftData
import Foundation

/// SwiftData persistent model for the authenticated user.
/// Mapped to the `User` domain struct via `toDomainUser()` and `User.toEntity()`.
@Model
final class UserEntity {
    @Attribute(.unique) var id: UUID
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
