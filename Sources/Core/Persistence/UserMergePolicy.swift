import Foundation

// MARK: - What a merge decided

/// The outcome of comparing a stored copy of a user against one that just
/// arrived from the API, together with the rule that produced it.
///
/// One flat enum rather than a `Bool` and a separate reason, because the two
/// cannot disagree if they are the same value. `acceptsRemote` is the answer a
/// caller acts on; the case itself is the answer a reader — or a log line, or a
/// failing test — needs in order to say *why*, and "the response was rejected"
/// is not a useful thing to read without it.
///
/// The raw value exists so a decision can be logged or asserted on by name
/// without a hand-written mapping, matching `SyncPolicy` and `SyncOrigin`.
package enum MergeDecision: String, Sendable, Equatable, CaseIterable {

    /// The store holds no copy of this user, so nothing can conflict with the
    /// response.
    case noLocalCopy

    /// The stored row is a different user. Not a conflict: it is the previous
    /// account's row, which nothing clears on sign-out yet — see
    /// `docs/offline-first.md`. A merge is a question about two copies of *one*
    /// profile, and this is not that question.
    case differentIdentity

    /// Both sides carry a revision and the response's is higher.
    case remoteWinsOnVersion

    /// Both sides carry a revision and the *stored* one is higher: the response
    /// is a copy of an older write. This is the case the whole item exists for.
    case localWinsOnVersion

    /// Both sides carry the same revision. The response is accepted, because
    /// writing an identical revision over itself changes no content and does
    /// refresh the row's confirmation stamp.
    case sameVersion

    /// A revision was missing on one or both sides, and the response's
    /// `updatedAt` is the later of the two.
    case remoteWinsOnTimestamp

    /// A revision was missing on one or both sides, and the *stored*
    /// `updatedAt` is the later of the two.
    case localWinsOnTimestamp

    /// A revision was missing on one or both sides and the two timestamps are
    /// equal, which is the ordinary case for a re-fetch of an unchanged
    /// profile. Accepted, for the same reason as `sameVersion`.
    case sameTimestamp

    /// Neither side can be ordered against the other: no pair of revisions, and
    /// no pair of timestamps. The response is accepted.
    ///
    /// This is the pre-versioning behaviour of this package, and keeping it as
    /// the floor is deliberate. A policy that refused to write when it could
    /// not prove the response was newer would turn every unversioned,
    /// untimestamped profile into a row that never refreshes again — a much
    /// worse failure than the clobber it would be avoiding, and a silent one.
    case unordered

    /// Whether the caller should write the response over the stored row.
    ///
    /// Spelled out case by case rather than as a `default`, so that a new
    /// decision cannot be added without answering this question for it.
    package var acceptsRemote: Bool {
        switch self {
        case .noLocalCopy, .differentIdentity: true
        case .remoteWinsOnVersion, .sameVersion: true
        case .remoteWinsOnTimestamp, .sameTimestamp: true
        case .unordered: true
        case .localWinsOnVersion, .localWinsOnTimestamp: false
        }
    }
}

// MARK: - The policy

/// Decides which of two copies of a user is the newer one.
///
/// A protocol, and not a function on `User`, for the reason every other policy
/// in this package is one: "which copy wins" is a product decision that an app
/// adopting this boilerplate may need to answer differently — a
/// field-level merge, a prompt to the person, an outbox that always defers to
/// the device — and the call site should not have to change when it does.
/// `OfflineFirstSyncStrategy` names this protocol and never names the
/// implementation.
package protocol UserMergePolicy: Sendable {

    /// - Parameters:
    ///   - local: The stored copy and its confirmation stamp, or `nil` when the
    ///     store holds no copy.
    ///   - remote: The copy that just came back from the API.
    func decide(local: StoredUser?, remote: User) -> MergeDecision
}

/// Last writer wins, where "last" is the server's revision counter and the
/// wall clock is only the fallback.
///
/// ## The rules, in the order they are applied
///
/// 1. No stored copy, or a stored copy of a *different* user — accept.
/// 2. Both sides carry a `version` — the higher one wins; equal accepts.
/// 3. Otherwise, both sides carry an `updatedAt` — the later one wins; equal
///    accepts.
/// 4. Otherwise — accept.
///
/// ## Why the version comes first
///
/// `updatedAt` is a wall-clock instant minted by whichever machine performed
/// the write, and this package already documents what a wall clock does to a
/// freshness window (`StoredUser.isFresh(at:maxAge:)`): it moves. Two writes a
/// second apart, from two machines whose clocks are two seconds apart, order
/// backwards — and unlike a stale freshness stamp, which costs one unnecessary
/// request, ordering a merge backwards costs the newer write, permanently and
/// silently.
///
/// A counter the server increments per accepted write has none of that. It
/// needs no clock, it cannot go backwards without the server saying so, and
/// equality means "the same write" rather than "within the same second".
///
/// ## Why the timestamp fallback exists anyway
///
/// `version` is optional on both sides, and it will be `nil` on every row this
/// app has already written — the column is new — and in every response from a
/// deployment that does not report it. A policy with no fallback would treat
/// all of those as `unordered` and accept blindly, which is exactly the
/// behaviour this item is here to replace. The fallback is weaker than the
/// counter and better than nothing, and the decision says which one it used, so
/// a caller can tell an ordered merge from a guess.
///
/// ## What it is not
///
/// It does not merge *fields*. The winner is a whole `User`, and a name edited
/// on this device is lost when the server's copy wins. Field-level merging
/// needs per-field provenance — which field changed, and when — and this
/// package has one writer per profile, so the value that would carry it does
/// not exist yet. See `docs/conflict-resolution.md`.
package struct LastWriterWinsMergePolicy: UserMergePolicy {

    package init() {}

    package func decide(local: StoredUser?, remote: User) -> MergeDecision {
        guard let local else { return .noLocalCopy }
        guard local.user.id == remote.id else { return .differentIdentity }

        if let storedVersion = local.user.version, let fetchedVersion = remote.version {
            return Self.compareVersions(stored: storedVersion, fetched: fetchedVersion)
        }
        if let storedAt = local.user.updatedAt, let fetchedAt = remote.updatedAt {
            return Self.compareTimestamps(stored: storedAt, fetched: fetchedAt)
        }
        return .unordered
    }

    private static func compareVersions(stored: Int, fetched: Int) -> MergeDecision {
        if fetched > stored { return .remoteWinsOnVersion }
        if fetched < stored { return .localWinsOnVersion }
        return .sameVersion
    }

    private static func compareTimestamps(stored: Date, fetched: Date) -> MergeDecision {
        if fetched > stored { return .remoteWinsOnTimestamp }
        if fetched < stored { return .localWinsOnTimestamp }
        return .sameTimestamp
    }
}

// MARK: - Failing a write on a conflict

/// A write whose response the merge policy rejected as older than the row it
/// would have replaced.
///
/// A read that hits this case has an answer to give — the row — so it returns
/// it and says `origin == .localCache`. A *write* does not: the caller asked
/// for a change and the server came back describing a profile older than the
/// one already on disk, which means the edit was not applied to the revision
/// the caller is looking at. Returning the stored row there would report
/// success for a write that did not happen, and returning the response would
/// undo whatever the row holds. So the write fails, loudly, with both revisions
/// in the error.
package struct MergeConflictError: LocalizedError, Sendable, Equatable {

    /// The decision that rejected the response, so a handler can tell an
    /// ordered rejection from one that fell back to timestamps.
    package let decision: MergeDecision

    /// The revision on the stored row, or `nil` when it carried none.
    package let storedVersion: Int?

    /// The revision in the response, or `nil` when it carried none.
    package let fetchedVersion: Int?

    package init(decision: MergeDecision, storedVersion: Int?, fetchedVersion: Int?) {
        self.decision = decision
        self.storedVersion = storedVersion
        self.fetchedVersion = fetchedVersion
    }

    package var errorDescription: String? {
        "This profile was changed elsewhere. The server replied with an older "
            + "copy than the one on this device, so the change was not saved."
    }
}

// MARK: - Double

/// Answers with the decision it was given, whatever it is asked.
///
/// It exists to pin that a caller *consults* the policy rather than comparing
/// versions itself: handed `.localWinsOnVersion` over two values whose
/// revisions say the opposite, a caller that reads the protocol keeps the row
/// and a caller that reimplemented the comparison does not.
///
/// A `struct` holding a `let`, so it is `Sendable` without a lock. It records
/// nothing, because there is nothing to record that the caller's own effect on
/// the store does not already show.
package struct StubbedMergePolicy: UserMergePolicy {

    private let decision: MergeDecision

    package init(_ decision: MergeDecision) {
        self.decision = decision
    }

    package func decide(local: StoredUser?, remote: User) -> MergeDecision {
        decision
    }
}
