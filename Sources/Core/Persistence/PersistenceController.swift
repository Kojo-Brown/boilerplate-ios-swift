import SwiftData
import Foundation

/// Configures and vends the app's `ModelContainer`.
/// Inject into the SwiftUI environment at the `@main` level:
/// ```swift
/// .modelContainer(try PersistenceController.makeContainer())
/// ```
///
/// Every container built here is built from `Schema(versionedSchema:)` over the
/// current version and carries `UserMigrationPlan`. Both halves matter and they
/// have to agree: the schema says what shape the app expects, the plan says how
/// a store in an older shape gets there, and `ModelContainer` rejects the pair
/// if the schema is not the plan's last version. Constructing a container any
/// other way — a bare `Schema([UserEntity.self])`, or the same schema with no
/// plan — is how a device that skipped a release ends up unable to open its own
/// store, so there is deliberately no entry point here that omits either.
package enum PersistenceController {
    /// The shape the running app expects, which is the last version in the plan.
    private static var currentSchema: Schema {
        Schema(versionedSchema: UserSchemaV3.self)
    }

    /// Disk-backed container for production use, at SwiftData's default store
    /// location.
    package static func makeContainer() throws -> ModelContainer {
        let schema = currentSchema
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try ModelContainer(for: schema, migrationPlan: UserMigrationPlan.self, configurations: config)
    }

    /// Disk-backed container at an explicit store URL.
    ///
    /// The app does not need this — it takes the default location — and it is
    /// not a testing hook bolted onto production code either: relocating the
    /// store into an app group is the ordinary reason to name a URL, and doing
    /// that by hand elsewhere would mean building a container without the
    /// migration plan.
    ///
    /// It is, in passing, the only way to exercise a migration at all.
    /// `makeInMemoryContainer()` starts empty every time, so there is never an
    /// older store for the plan to act on; `UserMigrationTests` writes one in
    /// an old shape to a temporary URL and opens it through here.
    package static func makeContainer(at url: URL) throws -> ModelContainer {
        let schema = currentSchema
        let config = ModelConfiguration(schema: schema, url: url)
        return try ModelContainer(for: schema, migrationPlan: UserMigrationPlan.self, configurations: config)
    }

    /// In-memory container for tests and SwiftUI previews.
    ///
    /// The migration plan is passed here too, even though an in-memory store is
    /// created fresh at the current version on every call and so can never have
    /// anything to migrate. The point is that the tests and previews build
    /// their container the same way the app does: a divergence in how the
    /// container is configured is exactly the kind of thing that makes a suite
    /// green against a container the app never has.
    package static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = currentSchema
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, migrationPlan: UserMigrationPlan.self, configurations: config)
    }
}
