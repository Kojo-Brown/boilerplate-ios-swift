import Foundation

/// Domain model representing an authenticated application user.
struct User: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let email: String
    var name: String
    var avatarURL: URL?

    init(id: UUID = UUID(), email: String, name: String, avatarURL: URL? = nil) {
        self.id = id
        self.email = email
        self.name = name
        self.avatarURL = avatarURL
    }
}
