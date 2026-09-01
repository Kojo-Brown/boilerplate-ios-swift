import Foundation
import SwiftData

/// The store as it shipped before any of the offline-first work: the six
/// mapped fields of `User`, and nothing about this device's copy of them.
///
/// This version is history. Nothing in the app builds a container from it and
/// no code path constructs one of its rows outside `UserMigrationTests` — it
/// exists so the migration plan has a *from* side that is written down rather
/// than inferred, and so a test can create a store in the old shape and prove
/// the current one opens it.
///
/// Keeping it is not optional the moment the plan exists. `SchemaMigrationPlan`
/// identifies a store on disk by matching its persisted metadata against the
/// versions in `schemas`; delete this one and a device that has not launched
/// since the `refreshedAt` change stops matching anything, which is the failure
/// mode a migration plan is there to prevent.
///
/// The entity is deliberately a bare data holder: no `toDomainUser()`, no
/// `overwrite(with:)`. A historical version's only job is to describe a shape
/// the store may still be in. Giving it behaviour would make it look like
/// something a caller could use, and would then have to be kept working as the
/// domain type moves on.
package enum UserSchemaV1: VersionedSchema {
    package static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    package static var models: [any PersistentModel.Type] { [UserEntity.self] }

    /// The class name — not the enclosing enum — is what SwiftData persists as
    /// the entity name, so this is the same `UserEntity` entity that
    /// `UserSchemaV3.UserEntity` describes, one shape earlier. That is what
    /// makes a lightweight stage between them possible at all: Core Data maps
    /// old rows to new by entity and attribute *name*.
    @Model
    package final class UserEntity {
        // No `@Attribute(.unique)` on `id`, here or in any later version, even
        // though the first draft of this entity carried one. That draft was
        // never compiled — the constraint was removed in the commit that made
        // this package build for the first time (#21), because it traps rather
        // than throws on an in-memory store, which is every store the tests and
        // previews run on. So no build ever produced a store with that
        // constraint in it, and a V1 that reinstated it here would be
        // describing a shape that has never existed on a device.
        package var id: UUID
        package var email: String
        package var name: String
        package var avatarURL: URL?
        package var createdAt: Date?
        package var updatedAt: Date?

        package init(
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
    }
}
