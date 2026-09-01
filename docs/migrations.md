# Schema migrations

The store on a user's device was written by whatever build they last ran, not by
this one. A migration plan is the app's answer to that: a written-down list of
every shape the store has ever had, and a stage for each step between them.

`Sources/Core/Persistence/Schema/` holds all of it.

| File | What it is |
| --- | --- |
| `UserSchemaV1.swift` | The six mapped fields of `User`. What shipped first. |
| `UserSchemaV2.swift` | V1 plus `refreshedAt`, the offline-first stamp. |
| `UserSchemaV3.swift` | V2 plus `version`, the server revision. Current. |
| `UserMigrationPlan.swift` | The three versions and the two stages between them. |

`UserEntity` — the name the rest of the package uses — is a typealias for
`UserSchemaV3.UserEntity`, declared in `Sources/Core/Persistence/UserEntity.swift`.
Adding a version moves that one line and nothing else in the package changes.

## Why a plan, when both changes so far migrated themselves

Both schema changes this app has made added a **new optional attribute**, and
that is precisely the change SwiftData performs with no plan at all: it adds the
column and fills existing rows with `nil`. Both migrations already worked. A
plan whose stages are both `.lightweight` looks, at first glance, like ceremony
laid over behaviour that was free.

Three things it buys that the implicit behaviour does not:

**Implicit migration has a cliff, and the first change past it is a bad moment
to be inventing history.** Renaming an attribute, making one non-optional,
splitting an entity, deriving a value from another — none of those migrate on
their own. Each needs a stage, and a stage needs a *from* version. That from
version is whatever actually shipped, which cannot be reconstructed later from a
tree where the entity has been edited in place. Writing V1, V2 and V3 down now
is what makes V4 a one-file change rather than an archaeology exercise.

**A store is identified by its shape, not by a number the app carries.**
SwiftData matches a store's persisted metadata against the versions in
`UserMigrationPlan.schemas` to work out where it is starting from. A device that
has not launched since before `refreshedAt` holds a store in V1's shape; if V1
is not in the list, nothing recognises it. This is why the old versions are kept
as real declarations rather than deleted once they stopped being current, and
why editing a shipped version in place is the one thing this layout forbids.

**Nothing proved any of it.** "Lightweight migration handles this" was a claim
in a doc comment. `Tests/ViewModelTests/UserMigrationTests.swift` writes a V1
store and a V2 store to a temporary file and opens them through
`PersistenceController`, which is the only arrangement where the plan does any
work — every other persistence suite runs on an in-memory container that is
created empty at the current version, so none of them can fail when a migration
is wrong.

## What the tests actually check

- A V1 store opens at the current schema with `refreshedAt` and `version` both
  `nil`. `nil` is the honest answer for both: the row was never confirmed
  against the API, and it carries no server revision. Neither is a default worth
  inventing — `StoredUser` and `UserMergePolicy` both read `nil` as *unknown*
  rather than as zero or as the epoch.
- Every row survives, not just the first.
- A V2 store keeps its refresh stamp. Losing it would fail nothing loudly; it
  would make the first read after an upgrade hit the network, which is the kind
  of regression nobody notices until someone measures it.
- Opening a migrated store a second time changes nothing.
- The service can still **write** to a migrated store, which is a stronger claim
  than being able to read one.
- The plan is ordered, contiguous, and ends at the version `PersistenceController`
  builds its container from — a mismatch there throws at launch.
- All three versions describe one entity named `UserEntity`. SwiftData persists
  an entity under a name taken from the class rather than from the version
  enclosing it, and a lightweight stage maps rows across by that name, so
  renaming the class in a new version would compile, pass every other test, and
  orphan every row on every device.

## Adding version 4

1. Copy `UserSchemaV3.swift` to `UserSchemaV4.swift`, bump the
   `versionIdentifier`, and make the change.
2. Point the `UserEntity` typealias at `UserSchemaV4.UserEntity`.
3. Append `UserSchemaV4.self` to `UserMigrationPlan.schemas` and a stage to
   `UserMigrationPlan.stages`.
4. Point `PersistenceController.currentSchema` at V4.
5. Add a test that seeds a V3 store and opens it at V4.

Do not edit a shipped version in place. A store written by an earlier build
would then be in a shape nothing describes, and the plan would have no way to
recognise it.

### When lightweight is not enough

`.custom(fromVersion:toVersion:willMigrate:didMigrate:)` is the stage that moves
data rather than just adding a column. `willMigrate` runs against the old shape —
read the values you are about to lose — and `didMigrate` against the new one,
where you write them wherever they now belong. Both take a `ModelContext` and
both must `save()`. Neither runs for a store already at or past that version, so
neither is a place for work that has to happen on every launch.

There is no custom stage in this plan today, and one has not been added for
demonstration. A stage that does nothing a lightweight stage would not do is a
worked example of migration machinery and a lie about this store's history, and
the second cost is the one that gets paid later.

## Where a container is built

Only in `PersistenceController`, and every entry point there pairs
`Schema(versionedSchema: UserSchemaV3.self)` with `UserMigrationPlan`.
`ModelContainer` rejects the pair if the schema is not the plan's last version,
so the two cannot silently disagree — but only if both are passed. Building a
container anywhere else, from a bare `Schema([UserEntity.self])` or from the
right schema with no plan, is how a device that skipped a release ends up unable
to open its own store. That is why `makeContainer(at:)` exists rather than
callers assembling a relocated store by hand, and why the in-memory container
carries the plan too even though it can never have anything to migrate: the
tests and previews should build their container the way the app does.
