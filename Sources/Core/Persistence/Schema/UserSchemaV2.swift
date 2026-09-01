import Foundation
import SwiftData

/// Version 1 plus `refreshedAt`: the first time the row started carrying a fact
/// about *this device's copy* rather than about the person.
///
/// Phase 9 item 1 added the attribute and said so in `UserEntity.swift`: a new
/// optional attribute is the one change SwiftData's implicit lightweight
/// migration performs with no plan at all, filling existing rows with `nil`,
/// which is what an unconfirmed row should say. That was true and it shipped
/// without a version identifier, so the shape existed on disk while nothing
/// named it. This is the name.
///
/// It matters that this version is written down separately from V1 even though
/// no stage between them does any work beyond adding a column. A store on a
/// device that installed between the two changes is in *this* shape, not V1's
/// and not V3's, and the plan can only route it if it can recognise it.
package enum UserSchemaV2: VersionedSchema {
    package static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    package static var models: [any PersistentModel.Type] { [UserEntity.self] }

    @Model
    package final class UserEntity {
        package var id: UUID
        package var email: String
        package var name: String
        package var avatarURL: URL?
        package var createdAt: Date?
        package var updatedAt: Date?

        /// When this row was last written from an API response, or `nil` when
        /// it has never been confirmed with the server.
        package var refreshedAt: Date?

        package init(
            id: UUID,
            email: String,
            name: String,
            avatarURL: URL? = nil,
            createdAt: Date? = nil,
            updatedAt: Date? = nil,
            refreshedAt: Date? = nil
        ) {
            self.id = id
            self.email = email
            self.name = name
            self.avatarURL = avatarURL
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.refreshedAt = refreshedAt
        }
    }
}
