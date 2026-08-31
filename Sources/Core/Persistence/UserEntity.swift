import SwiftData
import Foundation

/// SwiftData persistent model for the authenticated user.
/// Mapped to the `User` domain struct via `toDomainUser()` and `User.toEntity()`.
@Model
package final class UserEntity {
    // `id` deliberately carries no `@Attribute(.unique)`. SwiftData does not support
    // unique constraints on an in-memory store, and it does not report that by
    // throwing — it traps, on every operation against the container, `insert` and
    // `fetch` alike. `PersistenceController.makeInMemoryContainer()` is what previews
    // and the whole persistence test suite run on, so the constraint made the entity
    // unusable everywhere it was actually exercised.
    //
    // Little is given up. `id` is a `UUID` the app assigns before insert, never a value
    // the store derives, and nothing here relies on the upsert-on-conflict behaviour
    // `.unique` provides: `save(user:)` inserts, and `update(user:)` looks the row up
    // first. Uniqueness is enforced by where the identifier comes from.
    package var id: UUID
    package var email: String
    package var name: String
    package var avatarURL: URL?
    package var createdAt: Date?
    package var updatedAt: Date?

    /// When this row was last written from an API response, or `nil` when it
    /// has never been confirmed with the server.
    ///
    /// Storage metadata, not domain data: it is absent from `User` and from
    /// `toDomainUser()` on purpose, because "when did this device last hear
    /// from the server about this profile" is a fact about the copy and not
    /// about the person. `StoredUser` is what carries the pair to a caller that
    /// needs both, and `OfflineFirstSyncStrategy` is the only reader — a policy
    /// that decides whether to refresh has to survive a launch to be worth
    /// anything, and process memory does not.
    ///
    /// This is the first schema change since the store was introduced, and it
    /// is deliberately the cheapest shape of one: a **new optional attribute**,
    /// which SwiftData's implicit lightweight migration adds to an existing
    /// store without a migration plan, filling it with `nil` — which is exactly
    /// what an unconfirmed row should say. Versioned schemas and migration
    /// tests are Phase 9 item 4; this field is what that item will migrate
    /// *from*, and adding it without a `VersionedSchema` is a decision that
    /// item is meant to close, not one this comment pretends is closed.
    package var refreshedAt: Date?

    /// The server revision this row holds, or `nil` when it was written from a
    /// response that carried none.
    ///
    /// Domain data, unlike `refreshedAt`: it is a fact about the profile the
    /// server accepted, not about this device's copy of it, which is why it
    /// round-trips through `toDomainUser()` while the stamp does not. It has to
    /// survive a launch for the same reason the stamp does — `UserMergePolicy`
    /// compares an incoming response against the row, and a device that forgot
    /// which revision it holds has nothing to compare.
    ///
    /// Optional for two reasons that happen to agree. The API's field is
    /// optional (see `User.version`), and a new **optional** attribute is the
    /// one schema change SwiftData's implicit lightweight migration performs
    /// with no migration plan, filling existing rows with `nil` — which is
    /// exactly what a row written before this item should say. That is the same
    /// bargain `refreshedAt` struck, and it has the same caveat: Phase 9 item 4
    /// is where these columns get a `VersionedSchema` to migrate from.
    package var version: Int?

    package init(
        id: UUID,
        email: String,
        name: String,
        avatarURL: URL? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        refreshedAt: Date? = nil,
        version: Int? = nil
    ) {
        self.id = id
        self.email = email
        self.name = name
        self.avatarURL = avatarURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.refreshedAt = refreshedAt
        self.version = version
    }

    package func toDomainUser() -> User {
        User(
            id: id,
            email: email,
            name: name,
            avatarURL: avatarURL,
            createdAt: createdAt,
            updatedAt: updatedAt,
            version: version
        )
    }

    /// The row and its confirmation stamp, which is what a policy reads.
    package func toStoredUser() -> StoredUser {
        StoredUser(user: toDomainUser(), refreshedAt: refreshedAt)
    }

    /// Overwrites every mapped field from `user`.
    ///
    /// Every field, not the three an edit was once assumed to touch. The
    /// previous spelling of `update(user:)` assigned `name`, `avatarURL` and
    /// `updatedAt` and left `email` and `createdAt` on whatever the row already
    /// held, which was survivable while the store was a cache the API could
    /// correct — and is not survivable now that a read is answered from the
    /// row. An address changed on another device would have been written to
    /// disk, dropped on the floor, and then served back as the truth.
    ///
    /// `refreshedAt` is deliberately not touched here: this says what the row
    /// contains, and the caller says when it was confirmed. `version` *is*
    /// touched, and has to be — it travels with the value, so a row that took
    /// new content while keeping its old revision would claim to be a revision
    /// it is not, and would then lose the next merge it should have won.
    package func overwrite(with user: User) {
        id = user.id
        email = user.email
        name = user.name
        avatarURL = user.avatarURL
        createdAt = user.createdAt
        updatedAt = user.updatedAt
        version = user.version
    }
}

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
