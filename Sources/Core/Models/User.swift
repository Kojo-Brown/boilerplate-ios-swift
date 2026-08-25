import Foundation

/// Domain model representing an authenticated application user.
///
/// Every stored property is a `let`. `name`, `avatarURL`, `createdAt` and
/// `updatedAt` were `var`, which said something untrue about how this type is
/// used: nothing in the package has ever mutated a `User` in place. Every edit
/// already went through the server and came back as a fresh value, which is what
/// a domain model fetched over HTTP always does.
///
/// Making that a compile-time fact rather than a habit buys three things. A
/// `let`-only struct has no partially-updated state for a reader to worry about,
/// which is the same reason it is trivially `Sendable`. Two `User` values that
/// are `==` stay `==`, so it is safe as a SwiftUI identity or a dictionary key.
/// And an edit has to be spelled as a derivation, which is where `with(_:)`
/// comes in — see `FieldUpdate` for why its parameters are not plain optionals.
package struct User: Identifiable, Codable, Sendable, Equatable {
    package let id: UUID
    package let email: String
    package let name: String
    package let avatarURL: URL?
    package let createdAt: Date?
    package let updatedAt: Date?

    package init(
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

    package enum CodingKeys: String, CodingKey {
        case id
        case email
        case name
        case avatarURL = "avatar_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Derivation

extension User {
    /// The same user, with the named fields replaced.
    ///
    /// `id` and `email` are absent on purpose. The parameter list of a `with`
    /// transform is the type's statement about what an edit is allowed to
    /// touch, and changing either of those does not produce an edited user — it
    /// produces a different one, which the memberwise `init` is there for.
    ///
    /// Rebuilding the value by hand does the same job and drops fields while
    /// doing it. `MockUserRepository.updateProfile(name:)` used to read
    /// `User(id: stubbedUser.id, email: stubbedUser.email, name: name)`, which
    /// silently discarded the avatar and both timestamps because the memberwise
    /// initialiser defaults them to `nil`. A transform cannot lose a field it
    /// was not asked about.
    package func with(
        name: FieldUpdate<String> = .unchanged,
        avatarURL: FieldUpdate<URL?> = .unchanged,
        createdAt: FieldUpdate<Date?> = .unchanged,
        updatedAt: FieldUpdate<Date?> = .unchanged
    ) -> User {
        User(
            id: id,
            email: email,
            name: name.applied(to: self.name),
            avatarURL: avatarURL.applied(to: self.avatarURL),
            createdAt: createdAt.applied(to: self.createdAt),
            updatedAt: updatedAt.applied(to: self.updatedAt)
        )
    }
}
