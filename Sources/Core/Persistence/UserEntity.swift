import Foundation

/// The persistent model for the authenticated user, at whichever schema version
/// is current.
///
/// The declaration itself lives in `Schema/UserSchemaV3.swift`, nested inside
/// the version that describes it. Everything else in the package — the fetches
/// in `SwiftDataUserPersistenceService`, the assertions in the persistence
/// suites — names it through this alias and never through a version, so the
/// only edit a new schema version costs the rest of the package is the line
/// below.
///
/// This is also what keeps the class *name* stable, and the name is load
/// bearing: SwiftData persists an entity under its unqualified type name, so
/// `UserSchemaV1.UserEntity` and `UserSchemaV3.UserEntity` are two shapes of
/// one entity called `UserEntity`, which is precisely what lets a lightweight
/// stage map old rows onto new. Renaming the class would be a schema change
/// even if not one attribute moved.
package typealias UserEntity = UserSchemaV3.UserEntity

extension User {
    package func toEntity(refreshedAt: Date? = nil) -> UserEntity {
        UserEntity(
            id: id,
            email: email,
            name: name,
            avatarURL: avatarURL,
            createdAt: createdAt,
            updatedAt: updatedAt,
            refreshedAt: refreshedAt,
            version: version
        )
    }
}
