import Foundation

/// A stored `User` together with the moment that copy was last confirmed
/// against the API.
///
/// The two halves travel together because reading them separately is a torn
/// read: the row and its stamp come out of one fetch of one row, and a caller
/// that asked for the user and then asked for "when was that refreshed" could
/// be answered about two different writes.
///
/// `refreshedAt` is a wall-clock `Date` and not a `ContinuousClock.Instant`,
/// which is the opposite of the choice `CacheFirstSyncStrategy` makes and is
/// forced by what this value is for. A monotonic instant is meaningless once
/// the process that minted it is gone — it is an offset from an arbitrary
/// origin the next launch does not share — and surviving the launch is the
/// entire reason this field is persisted rather than held in memory. What that
/// costs is a clock that can move: see `isFresh(at:maxAge:)`.
package struct StoredUser: Sendable, Equatable {

    /// The row.
    package let user: User

    /// When the row was last written from an API response, or `nil` when the
    /// row has never been confirmed with the server — it was seeded, restored,
    /// or written by a caller that had no answer from the API to record.
    package let refreshedAt: Date?

    package init(user: User, refreshedAt: Date? = nil) {
        self.user = user
        self.refreshedAt = refreshedAt
    }

    /// How old the stored copy is at `instant`, or `nil` when it was never
    /// confirmed with the API.
    ///
    /// Negative when the stamp is in the future, which is not a hypothetical:
    /// the stamp is wall-clock, and a device that syncs its clock backwards or
    /// crosses a date line has moved `instant` behind a `refreshedAt` written
    /// before the change. Callers are expected to read the sign rather than
    /// only the magnitude — see `isFresh(at:maxAge:)`.
    package func age(at instant: Date) -> TimeInterval? {
        guard let refreshedAt else { return nil }
        return instant.timeIntervalSince(refreshedAt)
    }

    /// Whether the stored copy is young enough to answer a read without going
    /// to the API.
    ///
    /// Three things are stale, and only the first is obvious:
    ///
    /// * a copy older than `maxAge`;
    /// * a copy that was never confirmed with the API at all, because "no
    ///   stamp" is not "fresh";
    /// * a copy stamped in the *future*, because the only way that happens is a
    ///   clock that moved, and a window measured against a moved clock could
    ///   otherwise hold for as long as the clock is wrong. Treating it as stale
    ///   costs one request; trusting it costs a device that never refreshes
    ///   until the skew is corrected.
    package func isFresh(at instant: Date, maxAge: Duration) -> Bool {
        guard let age = age(at: instant) else { return false }
        return age >= 0 && age < maxAge.seconds
    }
}

extension Duration {
    /// This duration as a `TimeInterval`, for comparison against the
    /// `Date`-based arithmetic a persisted stamp forces.
    ///
    /// `Duration` is the type the sync policies express their windows in, and
    /// `Date.timeIntervalSince(_:)` is what a wall-clock age comes back as.
    /// Something has to convert, and doing it here keeps every window in the
    /// package spelled as a `Duration` at the point it is configured.
    package var seconds: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
    }
}
