import Foundation
import os

// MARK: - The seam

/// How many background refreshes have failed in a row.
///
/// One number, and it has to survive a process death — which is the whole
/// reason it is a protocol with a persisted implementation rather than a
/// property on the coordinator.
///
/// A background task is not a loop inside a running app. Each launch is very
/// often a *new process*: the system wakes the app, runs the handler, and
/// suspends or terminates it again, so anything the last attempt learned is
/// gone by the time the next one starts. An in-memory failure count therefore
/// reads zero on almost every run, and a backoff computed from it is not a
/// backoff — it schedules the same nominal interval forever, which is precisely
/// the behaviour the retry policy exists to avoid when a server is down.
///
/// `Retry` is the in-flight half of this and cannot substitute for it: it backs
/// off *within* one call, over seconds, against a task that is still alive. The
/// gap between two background launches is measured in minutes to hours and
/// spans a process boundary, so the two are different mechanisms answering
/// different failures, and `BackgroundRefreshCoordinator` uses both.
package protocol BackgroundRefreshLedger: Sendable {

    /// Refreshes that have failed since the last successful one.
    var consecutiveFailures: Int { get }

    /// Records a refresh that reached the API and got an answer. Resets the
    /// count to zero.
    func recordSuccess()

    /// Records a refresh that did not. Increments the count.
    func recordFailure()
}

// MARK: - The persisted implementation

/// The failure count in `UserDefaults`.
///
/// `UserDefaults` and not the Keychain: CLAUDE.md's rule is that *tokens* never
/// go in defaults, and this is a small integer with no secrecy requirement, no
/// value to an attacker, and nothing to lose from a backup restore that carries
/// it. Reaching for the Keychain here would be cargo-culting the rule past the
/// thing it protects.
///
/// The type stores a key and a suite name — two strings — and never the
/// `UserDefaults` instance itself. That is the same choice, and for the same
/// reason, as `SystemBackgroundTaskScheduler` not storing a `BGTaskScheduler`:
/// holding a framework class with no `Sendable` conformance would cost an
/// `@unchecked Sendable` on a type whose entire state is two strings. Resolving
/// the suite per call reaches a cached singleton and keeps the conformance
/// honest.
package struct UserDefaultsBackgroundRefreshLedger: BackgroundRefreshLedger {

    /// The defaults key. Namespaced by the task identifier by
    /// `init(taskIdentifier:)`, so two scheduled tasks in one app cannot share
    /// a backoff and pace each other.
    package let key: String

    /// The suite to read and write. `nil` is `UserDefaults.standard`.
    package let suiteName: String?

    package init(key: String, suiteName: String? = nil) {
        self.key = key
        self.suiteName = suiteName
    }

    /// The ledger for one scheduled task.
    package init(taskIdentifier: String, suiteName: String? = nil) {
        self.init(key: "background-refresh.consecutive-failures.\(taskIdentifier)", suiteName: suiteName)
    }

    /// Resolved per call rather than stored. See the type's documentation.
    ///
    /// A suite name that no longer resolves falls back to `.standard` rather
    /// than trapping: losing a backoff count is not worth crashing a background
    /// launch over, and the fallback is a real store rather than a discard.
    private var defaults: UserDefaults {
        guard let suiteName, let suite = UserDefaults(suiteName: suiteName) else {
            return .standard
        }
        return suite
    }

    /// `UserDefaults.integer(forKey:)` answers 0 for a missing key, which is
    /// the correct reading here — nothing has failed yet.
    package var consecutiveFailures: Int {
        max(0, defaults.integer(forKey: key))
    }

    package func recordSuccess() {
        defaults.removeObject(forKey: key)
    }

    /// Clamped, because the count is an exponent.
    ///
    /// `BackgroundRefreshCoordinator` advances a `Backoff.Schedule` once per
    /// recorded failure to find the next delay, so an unbounded count is an
    /// unbounded loop on a device that has been offline for a month. The
    /// ceiling costs nothing: every term past `Backoff.cap` is the cap, so a
    /// count of 32 and a count of 32,000 schedule the same launch.
    package func recordFailure() {
        let next = min(consecutiveFailures + 1, UserDefaultsBackgroundRefreshLedger.failureCeiling)
        defaults.set(next, forKey: key)
    }

    /// The point past which counting further changes no decision.
    package static let failureCeiling = 32
}

// MARK: - Double

/// The same ledger in memory, for tests and previews.
///
/// It applies the same ceiling as the persisted one. A double that let the
/// count run away would make the clamp untestable through the coordinator,
/// which is the only place the clamp matters.
package final class InMemoryBackgroundRefreshLedger: BackgroundRefreshLedger {

    private let count: OSAllocatedUnfairLock<Int>

    package init(consecutiveFailures: Int = 0) {
        count = OSAllocatedUnfairLock(initialState: max(0, consecutiveFailures))
    }

    package var consecutiveFailures: Int { count.withLock { $0 } }

    package func recordSuccess() {
        count.withLock { $0 = 0 }
    }

    package func recordFailure() {
        count.withLock {
            $0 = min($0 + 1, UserDefaultsBackgroundRefreshLedger.failureCeiling)
        }
    }
}
