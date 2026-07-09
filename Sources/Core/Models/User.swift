import Foundation

/// Domain model representing an authenticated application user.
struct User: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let email: String
    var name: String
    var avatarURL: URL?
    var createdAt: Date?
    var updatedAt: Date?

    init(
        id: UUID = UUID(),
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

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case name
        case avatarURL = "avatar_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
