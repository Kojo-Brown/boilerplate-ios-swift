import SwiftData
import Foundation

/// Configures and vends the app's `ModelContainer`.
/// Inject into the SwiftUI environment at the `@main` level:
/// ```swift
/// .modelContainer(try PersistenceController.makeContainer())
/// ```
enum PersistenceController {
    /// Disk-backed container for production use.
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([UserEntity.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// In-memory container for tests and SwiftUI previews.
    static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([UserEntity.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }
}
