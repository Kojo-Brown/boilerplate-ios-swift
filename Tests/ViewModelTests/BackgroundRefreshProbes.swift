import Foundation
import os
@testable import Core

// The doubles and builders the three background-refresh suites share, following
// `RetryProbes` and `EventProbes`: they are internal to the test module rather
// than `private` to one file because the suites had to be split — `file_length`
// is a `--strict` error at 500 counted lines and one file held them all — and a
// probe duplicated across two files is a probe that can drift between them.
//
// The names are prefixed rather than generic (`refreshClockOrigin`, not `now`)
// because module scope is a shared namespace: a second suite adding its own
// `fixedNow` would be a build failure in a file its author never opened.

// MARK: - Probes shared by the background-refresh suites

/// A wall clock that does not move.
///
/// `earliestBeginDate` is an absolute `Date`, so every assertion here is
/// "now plus exactly this many seconds" and needs an origin that two `#expect`s
/// in the same test agree on. `Date()` read twice is not one.
let refreshClockOrigin = Date(timeIntervalSince1970: 1_700_000_000)

let refreshTestIdentifier = "com.example.boilerplate-ios-swift.tests.refresh"

/// A refresh whose behaviour a test scripts attempt by attempt.
///
/// It counts calls as well as answering them, because the difference between
/// "the in-flight retry ran" and "the launch was rescheduled" is a difference
/// in the call count and nothing else.
final class ScriptedRefresh: Sendable {

    private struct State: Sendable {
        var calls = 0
        var observedSubmissions: [Int] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let failures: [any Error & Sendable]
    private let scheduler: MockBackgroundTaskScheduler?

    /// - Parameters:
    ///   - failures: One entry per attempt, from the first. Attempts past the
    ///     end of the list succeed, so `[timeout]` is "fails once, then works".
    ///   - scheduler: Watched from inside the work, so a test can assert what
    ///     had already been submitted *before* the refresh ran.
    init(failures: [any Error & Sendable] = [], scheduler: MockBackgroundTaskScheduler? = nil) {
        self.failures = failures
        self.scheduler = scheduler
    }

    var calls: Int { state.withLock { $0.calls } }

    /// How many requests the scheduler had accepted at the moment each attempt
    /// started.
    var observedSubmissions: [Int] { state.withLock { $0.observedSubmissions } }

    var work: @Sendable () async throws -> Void {
        { [self] in
            let alreadySubmitted = scheduler?.submitted.count ?? 0
            let attempt = state.withLock { current -> Int in
                current.observedSubmissions.append(alreadySubmitted)
                current.calls += 1
                return current.calls - 1
            }
            guard attempt < failures.count else { return }
            throw failures[attempt]
        }
    }
}

/// A sleep that records instead of waiting.
final class RecordingSleep: Sendable {

    private let slept = OSAllocatedUnfairLock<[Duration]>(initialState: [])

    var durations: [Duration] { slept.withLock { $0 } }

    var sleep: Retry.Sleep {
        let locked = slept
        return { duration in locked.withLock { $0.append(duration) } }
    }
}

/// Builds a coordinator with everything faked and nothing random.
///
/// `randomness` defaults to 1, which with `.equal` jitter draws the top of each
/// range — so a delay is the exact exponential term and an assertion can be an
/// equality rather than a tolerance.
func makeRefreshCoordinator(
    policy: BackgroundRefreshPolicy,
    scheduler: MockBackgroundTaskScheduler,
    ledger: any BackgroundRefreshLedger,
    sleep: @escaping Retry.Sleep = { _ in },
    randomness: @escaping Backoff.UnitRandom = { 1 },
    refresh: @escaping @Sendable () async throws -> Void
) -> BackgroundRefreshCoordinator {
    BackgroundRefreshCoordinator(
        policy: policy,
        scheduler: scheduler,
        ledger: ledger,
        subsystem: "com.example.boilerplate-ios-swift.tests",
        now: { refreshClockOrigin },
        sleep: sleep,
        randomness: randomness,
        refresh: refresh
    )
}

/// A minute between refreshes and five between failures, so "backed off" and
/// "nominal" are never the same number.
func makeRefreshPolicy(
    kind: BackgroundRefreshKind = .appRefresh
) -> BackgroundRefreshPolicy {
    BackgroundRefreshPolicy(
        identifier: refreshTestIdentifier,
        kind: kind,
        interval: .seconds(60),
        failureBackoff: Backoff(
            base: .seconds(300),
            multiplier: 2,
            cap: .seconds(3600),
            jitter: .equal
        ),
        inFlightRetry: Retry.Policy(
            maxAttempts: 2,
            backoff: Backoff(base: .seconds(1), multiplier: 2, cap: .seconds(4), jitter: .full)
        )
    )
}
