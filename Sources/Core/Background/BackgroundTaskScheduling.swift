import BackgroundTasks
import Foundation
import os

// MARK: - The seam

/// Submitting and cancelling background task requests.
///
/// One protocol over two `BGTaskScheduler` calls, and it exists because that
/// class cannot be driven from a test bundle at all: `submit(_:)` raises
/// `NSInternalInconsistencyException` for an identifier that is not in the
/// host's `BGTaskSchedulerPermittedIdentifiers`, and a unit-test bundle has no
/// such array to be in. Not a thrown error — a raised exception, which in Swift
/// is a trap and not something a `do/catch` can be written around. So a
/// coordinator that reached for `BGTaskScheduler.shared` directly would be a
/// coordinator whose scheduling policy could only ever be verified by running
/// the app and waiting, which for a background task means waiting hours.
///
/// Registration is deliberately not here. It is a launch-time act with a
/// different shape — it hands the system a closure to call later, rather than
/// asking it for something — and SwiftUI's `.backgroundTask(.appRefresh(_:))`
/// scene modifier already does it correctly, including the
/// `setTaskCompleted(success:)` and expiration plumbing that is the usual
/// source of "task never runs again" bugs. `BoilerplateApp` uses that modifier;
/// see `docs/background-refresh.md`.
package protocol BackgroundTaskScheduling: Sendable {

    /// Asks the system to launch the described task no earlier than
    /// `request.earliestBeginDate`.
    ///
    /// Submitting an identifier that already has a pending request replaces it
    /// rather than adding a second one, which is what makes
    /// `BackgroundRefreshCoordinator`'s schedule-then-work-then-reschedule
    /// sequence safe rather than wasteful.
    func submit(_ request: BackgroundRefreshRequest) throws

    /// Drops any pending request for `identifier`. A no-op when there is none.
    func cancel(identifier: String)
}

// MARK: - The system implementation

/// `BGTaskScheduler.shared`, behind the seam.
///
/// It stores nothing — not even the scheduler — and that is a deliberate choice
/// rather than an accident of having no state to keep. `BGTaskScheduler` is a
/// framework class with no `Sendable` conformance, so holding one would make
/// this type `@unchecked Sendable`: a promise the compiler stops checking, and
/// one that `.github/scripts/assert-sendable-audit.py` would then require an
/// entry for. Reading `.shared` inside each call keeps the value from ever
/// crossing an isolation boundary, costs a message send to a cached singleton,
/// and leaves the type trivially `Sendable` for real.
package struct SystemBackgroundTaskScheduler: BackgroundTaskScheduling {

    package init() {}

    package func submit(_ request: BackgroundRefreshRequest) throws {
        try BGTaskScheduler.shared.submit(request.systemRequest())
    }

    package func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

// MARK: - Double

/// Records what was submitted and answers with what it was told to.
///
/// State lives in a lock rather than under `@MainActor`, following
/// `MockSyncStrategy` and `MockAPIClient`: the type it stands in for is
/// nonisolated, and isolating the double would hide the hop it exists to fake.
package final class MockBackgroundTaskScheduler: BackgroundTaskScheduling {

    private struct State: Sendable {
        var submitted: [BackgroundRefreshRequest] = []
        var cancelled: [String] = []
        var submitError: (any Error & Sendable)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package init() {}

    /// Every request submitted, in order. The order is the interesting part:
    /// the coordinator submits once before the work and once after it, and a
    /// test that only looked at the last one could not tell a run that
    /// rescheduled itself twice from one that never scheduled anything until it
    /// had already finished.
    package var submitted: [BackgroundRefreshRequest] { state.withLock { $0.submitted } }

    /// Identifiers passed to `cancel(identifier:)`, in order.
    package var cancelled: [String] { state.withLock { $0.cancelled } }

    /// What the next and every subsequent `submit` throws. `nil` accepts.
    package var submitError: (any Error & Sendable)? {
        get { state.withLock { $0.submitError } }
        set { state.withLock { $0.submitError = newValue } }
    }

    package func submit(_ request: BackgroundRefreshRequest) throws {
        // The error is read out under the lock and thrown outside it: a
        // `withLock` body is not the place to unwind from.
        let failure = state.withLock { current -> (any Error & Sendable)? in
            guard current.submitError == nil else { return current.submitError }
            current.submitted.append(request)
            return nil
        }
        if let failure { throw failure }
    }

    package func cancel(identifier: String) {
        state.withLock { $0.cancelled.append(identifier) }
    }
}
