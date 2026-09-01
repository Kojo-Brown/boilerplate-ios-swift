import Foundation
import SwiftData

/// How a store written by an older build becomes a store the current build can
/// open.
///
/// ## Why this exists when both changes so far migrated themselves
///
/// Every schema change this app has made — `refreshedAt` in V2, `version` in
/// V3 — is a new optional attribute, and SwiftData performs exactly that change
/// with no plan at all: it adds the column and fills existing rows with `nil`.
/// So the two shipped migrations already worked, and a plan whose stages are
/// both `.lightweight` looks like ceremony over behaviour that was free.
///
/// It is not, for three reasons that only show up later:
///
///   * **Implicit migration has a cliff.** It handles added optional
///     attributes, added models, and little else. Renaming an attribute,
///     making one non-optional, splitting an entity or deriving a value from
///     another all need a stage — and the first such change is a bad moment to
///     also be inventing the version history it has to migrate *from*, because
///     that history is whatever shipped, not whatever is convenient. Writing
///     V1, V2 and V3 down now is what makes V4 a one-file change.
///   * **A store is identified by shape, not by a number in the app.**
///     SwiftData matches the persisted metadata against `schemas` to work out
///     where a store is starting from. A device that has not launched since
///     before `refreshedAt` is in V1's shape; if V1 is not listed, nothing
///     recognises it. This is why the historical versions are kept as real
///     declarations rather than deleted once they stopped being current.
///   * **Nothing proved it.** "Lightweight migration handles this" was a claim
///     in a doc comment. `UserMigrationTests` writes a V1 store and a V2 store
///     to disk and opens them through `PersistenceController`, which is the
///     only way to know the app can open what it shipped.
///
/// ## Adding a version
///
/// Copy `UserSchemaV3.swift` to `UserSchemaV4.swift` with the new shape, move
/// the `UserEntity` typealias onto V4, append V4 to `schemas` and a stage to
/// `stages`. Never edit a shipped version in place: a store on disk would then
/// be in a shape nothing describes.
///
/// A stage that needs to move data rather than just add a column is
/// `.custom(fromVersion:toVersion:willMigrate:didMigrate:)`. `willMigrate` runs
/// against the old shape (read the values you are about to lose), `didMigrate`
/// against the new one (write them where they now belong), and both take a
/// `ModelContext` and must `save()`. Neither closure runs for a store that is
/// already at or past that version, so they are not a place to put work that
/// has to happen on every launch.
package enum UserMigrationPlan: SchemaMigrationPlan {

    /// Every shape this store has ever had on a user's device, oldest first.
    ///
    /// The order is the migration path, so it is ascending and contiguous —
    /// `UserMigrationTests.thePlanIsOrderedAndContiguous` is the pin, because a
    /// version appended in the wrong place fails at nothing until a real device
    /// with an old store tries to launch.
    package static var schemas: [any VersionedSchema.Type] {
        [
            UserSchemaV1.self,
            UserSchemaV2.self,
            UserSchemaV3.self,
        ]
    }

    /// One stage per adjacent pair of versions.
    ///
    /// Both are `.lightweight`, because both changes are a new optional
    /// attribute and `nil` is the right value for a row that predates it: a row
    /// written before V2 was never confirmed against the API, and a row written
    /// before V3 carries no server revision. Neither of those is a default that
    /// wants inventing — see `StoredUser` and `UserMergePolicy`, both of which
    /// treat `nil` as "unknown" and not as zero.
    ///
    /// Spelled as a computed property rather than stored `static let`s so that
    /// nothing here is a mutable or non-`Sendable` global under Swift 6.
    package static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: UserSchemaV1.self, toVersion: UserSchemaV2.self),
            .lightweight(fromVersion: UserSchemaV2.self, toVersion: UserSchemaV3.self),
        ]
    }
}
