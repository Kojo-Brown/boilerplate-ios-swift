import Foundation
import os

// MARK: - What a launch produced

/// How one background launch ended.
///
/// Returned rather than logged-and-discarded so the policy is assertable: every
/// claim `BackgroundRefreshCoordinator` makes about what it reschedules, and
/// when, is a claim about which of these three it took and what it submitted on
/// the way out.
package enum BackgroundRefreshOutcome: String, Sendable, Equatable, CaseIterable {
    /// The work completed. The failure count is cleared and the next launch is
    /// asked for at the nominal interval.
    case refreshed
    /// The work threw, after exhausting its in-flight retries. The failure count
    /// is incremented and the next launch is pushed out by the backoff.
    case failed
    /// The system took the time back — the task expired, or the surrounding
    /// task was cancelled. Not counted as a failure: nothing was learned about
    /// whether the work *would* have succeeded.
    case expired
}

// MARK: - The policy

/// What to ask the system for, how often, and how to behave when it does not
/// work.
package struct BackgroundRefreshPolicy: Sendable {

    /// The task identifier, which must also be in the app's
    /// `BGTaskSchedulerPermittedIdentifiers`.
    package let identifier: String

    /// Which `BGTaskRequest` subclass to submit, and its constraints.
    package let kind: BackgroundRefreshKind

    /// The nominal spacing between successful refreshes, and a floor rather
    /// than a promise — the system launches when it decides to, and this only
    /// says "not before".
    package let interval: Duration

    /// How far out a *failed* refresh pushes the next launch, grown once per
    /// consecutive failure.
    ///
    /// The default differs from `Backoff()`'s in two ways, and both are about
    /// the units this schedule is measured in.
    ///
    /// The base is the nominal interval rather than 100ms, because there is no
    /// such thing as retrying a background task in a tenth of a second: the
    /// delay is a floor on a launch the system already paces at minutes.
    ///
    /// The jitter is `.equal` rather than `.full`, which is the more
    /// interesting departure. `.full` draws uniformly from `0...term`, so a
    /// device on its ninth consecutive failure can still ask to be launched
    /// almost immediately — the schedule's *expected* delay grows while its
    /// *floor* stays at zero. In a retry loop that is fine and deliberate,
    /// because the loop is bounded and the spreading is worth more than any one
    /// client's latency. Here the loop is unbounded, each attempt costs a
    /// process launch and a radio wake, and a phone that has been offline all
    /// day should not still be waking up every few minutes to find out. `.equal`
    /// keeps half of each term deterministic, so the backoff has a floor that
    /// actually grows, and randomises the other half — which is the part that
    /// keeps a million devices from all coming back the moment an outage ends.
    package let failureBackoff: Backoff

    /// The retry budget *within* one launch.
    ///
    /// Small on purpose. A `BGAppRefreshTask` gets tens of seconds, so a policy
    /// with a generous attempt count and a 30-second cap does not produce four
    /// attempts — it produces one attempt and an expiration, and expiration is
    /// the outcome that teaches the ledger nothing. Anything that needs longer
    /// than this is a `.processing` task, not a bigger retry budget.
    package let inFlightRetry: Retry.Policy

    package init(
        identifier: String,
        kind: BackgroundRefreshKind = .appRefresh,
        interval: Duration = .seconds(900),
        failureBackoff: Backoff? = nil,
        inFlightRetry: Retry.Policy = BackgroundRefreshPolicy.defaultInFlightRetry
    ) {
        self.identifier = identifier
        self.kind = kind
        self.interval = interval
        self.failureBackoff = failureBackoff ?? BackgroundRefreshPolicy.backoff(base: interval)
        self.inFlightRetry = inFlightRetry
    }

    /// Two attempts, seconds apart, and only for transport failures.
    ///
    /// `Retry.isTransient` is what makes this safe to run unattended: a 401 in
    /// the background is not retried, it is a failed refresh that backs off and
    /// lets the next foreground launch deal with the session.
    package static let defaultInFlightRetry = Retry.Policy(
        maxAttempts: 2,
        backoff: Backoff(base: .seconds(2), multiplier: 2, cap: .seconds(8), jitter: .full)
    )

    /// The reschedule schedule for a given nominal interval: doubling from the
    /// interval itself, capped at six hours, half-deterministic.
    ///
    /// Six hours rather than a day: past that the app is not backing off, it has
    /// stopped, and a user who fixes their connection at lunchtime should not
    /// wait until the following morning for the data to catch up.
    package static func backoff(base: Duration) -> Backoff {
        // `max` rather than the constant alone: `Backoff` requires `cap >= base`
        // and traps otherwise, so an app that legitimately refreshes once a day
        // must not crash on the line that builds its default backoff.
        Backoff(base: base, multiplier: 2, cap: max(.seconds(21_600), base), jitter: .equal)
    }
}

// MARK: - The coordinator

/// Keeps a background refresh scheduled, runs it when the system launches it,
/// and decides when to ask for the next one.
///
/// ## The three-line problem this exists to solve
///
/// The shape everyone writes first lives inside the launch handler and is
/// wrong in a way that does not show up until the network does:
///
/// ```swift
/// BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
///     Task {
///         try? await refresh()                 // ← 1, 2
///         schedule(after: .minutes(15))        // ← 3
///         task.setTaskCompleted(success: true)
///     }
/// }
/// ```
///
/// **1. `try?` throws the outcome away.** The system rations background time by
/// how useful the app's previous launches were, and `setTaskCompleted(success:)`
/// is how it is told. Reporting success for a run that failed spends the app's
/// budget on launches that do nothing; a refresh whose failures are invisible is
/// a refresh nobody notices has stopped working.
///
/// **2. A failure retries on the same schedule as a success.** A server that is
/// down gets asked again in fifteen minutes, and again, and again, at exactly
/// the rate it was being asked when it was healthy — from every installation at
/// once. That is the load pattern `Backoff` documents, arriving over hours
/// rather than seconds and from a client that is not even running.
///
/// **3. The reschedule is on the success path.** Anything that leaves the
/// handler early — a throw, an expiration, a crash — leaves *nothing pending*,
/// and a background task with no pending request is never launched again.
/// There is no retry, no error, and no log: the feature simply stops, usually
/// on the devices where it was already struggling. This is the single most
/// common way background refresh dies in shipped apps.
///
/// This type answers all three: `handle()` submits the next request **before**
/// running the work so an interrupted launch still has a successor, returns the
/// outcome so the caller can report it honestly, and pushes the next launch out
/// by a `Backoff` term grown from a *persisted* failure count — see
/// `BackgroundRefreshLedger` for why an in-memory count would be no count at
/// all.
///
/// ## Two submissions per launch is deliberate, not a leak
///
/// `handle()` submits at entry and again once the outcome is known. Submitting
/// an identifier that already has a pending request replaces it rather than
/// queueing a second, so the cost is one extra call and the benefit is that
/// there is no window in which the chain is broken.
///
/// ## Expiration is cancellation
///
/// The system gives a task an expiration handler and then kills it shortly
/// after. SwiftUI's `.backgroundTask(.appRefresh(_:))` wires that to cancelling
/// the surrounding `Task`, so this type needs no expiration API of its own: it
/// runs the work through `Retry.run`, which refuses to retry a cancelled
/// operation, and reports `.expired` rather than counting a failure the network
/// never caused.
package final class BackgroundRefreshCoordinator: Sendable {

    private let policy: BackgroundRefreshPolicy
    private let scheduler: any BackgroundTaskScheduling
    private let ledger: any BackgroundRefreshLedger
    private let refresh: @Sendable () async throws -> Void
    private let now: @Sendable () -> Date
    private let sleep: Retry.Sleep
    private let randomness: Backoff.UnitRandom
    private let logger: Logger

    /// - Parameters:
    ///   - policy: What to ask for and how to behave when it fails.
    ///   - scheduler: The submit/cancel seam. `SystemBackgroundTaskScheduler`
    ///     in the app.
    ///   - ledger: Where the consecutive-failure count is kept across launches.
    ///   - subsystem: The unified-log subsystem outcomes are filed under.
    ///   - now: The wall clock. Wall rather than monotonic because
    ///     `earliestBeginDate` is a `Date` the system compares against its own
    ///     clock, and injected so a test can assert the exact instant submitted
    ///     rather than a tolerance around it.
    ///   - sleep: How the in-flight retry waits. Injected for tests; the
    ///     default is cancellable, which is what makes an expiring task stop
    ///     mid-backoff instead of at the end of one.
    ///   - randomness: The jitter source, shared by both schedules.
    ///   - refresh: The work. Throwing means "this launch did not refresh
    ///     anything" — see `AppContainer.live` for why a read answered out of
    ///     the local store has to throw here rather than return.
    package init(
        policy: BackgroundRefreshPolicy,
        scheduler: any BackgroundTaskScheduling,
        ledger: any BackgroundRefreshLedger,
        subsystem: String,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping Retry.Sleep = Retry.taskSleep,
        randomness: @escaping Backoff.UnitRandom = Backoff.systemRandom,
        refresh: @escaping @Sendable () async throws -> Void
    ) {
        self.policy = policy
        self.scheduler = scheduler
        self.ledger = ledger
        self.now = now
        self.sleep = sleep
        self.randomness = randomness
        self.refresh = refresh
        logger = Logger(subsystem: subsystem, category: "BackgroundRefresh")
    }

    /// The identifier this coordinator schedules, for the caller that has to
    /// register the same string with the system.
    package var identifier: String { policy.identifier }

    // MARK: - Scheduling

    /// Asks the system for the next launch, at whatever delay the current
    /// failure count implies.
    ///
    /// This is the *explicit* entry point — app launch, and entering the
    /// background — and it throws, because there the caller is alive, has a
    /// screen, and a `BGTaskScheduler` rejection means the app is misconfigured
    /// (an identifier missing from the Info.plist array) rather than unlucky.
    /// The reschedules inside `handle()` cannot propagate anywhere useful and
    /// are logged instead.
    package func scheduleNext() throws {
        try scheduler.submit(request(after: delay(afterFailures: ledger.consecutiveFailures)))
    }

    /// Drops the pending request. Used when the feature is turned off — after
    /// sign-out, say, where continuing to wake up and ask for a profile nobody
    /// is signed in to is both pointless and a privacy question.
    package func cancel() {
        scheduler.cancel(identifier: policy.identifier)
    }

    // MARK: - Running

    /// Runs the refresh for one system launch and leaves the next one pending.
    ///
    /// - Returns: What happened, which the caller reports to the system as the
    ///   launch's success. `.expired` is *not* success: the work did not
    ///   finish, and telling the system otherwise is how an app's background
    ///   budget gets spent on launches that never complete.
    @discardableResult
    package func handle() async -> BackgroundRefreshOutcome {
        // Before anything that can be killed. See "Two submissions per launch".
        submit(after: delay(afterFailures: ledger.consecutiveFailures), reason: "entry")

        do {
            try await Retry.run(policy.inFlightRetry, randomness: randomness, sleep: sleep) { _ in
                try await self.refresh()
            }
        } catch {
            // Cancellation arrives as `CancellationError` from `Retry.run`'s own
            // check and as `URLError(.cancelled)` from a request that was in
            // flight, so the flag is consulted as well as the type — the same
            // pair `Retry` itself matches on.
            if error is CancellationError || Task.isCancelled {
                let message = "Background refresh expired before finishing; the next launch is already pending."
                logger.notice("\(message, privacy: .public)")
                return .expired
            }

            ledger.recordFailure()
            let failures = ledger.consecutiveFailures
            let message = "Background refresh failed \(failures)x in a row: \(error.localizedDescription)"
            logger.error("\(message, privacy: .public)")
            submit(after: delay(afterFailures: failures), reason: "failure")
            return .failed
        }

        ledger.recordSuccess()
        let message = "Background refresh succeeded; the failure count is cleared."
        logger.info("\(message, privacy: .public)")
        submit(after: policy.interval, reason: "success")
        return .refreshed
    }

    // MARK: - The schedule

    /// How long until the next launch may begin.
    ///
    /// Zero failures is the nominal interval. Each recorded failure advances
    /// the backoff one term, so the delay is the *n*-th term of the schedule
    /// rather than the first — which is the whole point of persisting the
    /// count, and is why this walks the schedule instead of asking it once.
    /// `UserDefaultsBackgroundRefreshLedger` clamps the count, so the walk is
    /// bounded by construction.
    private func delay(afterFailures failures: Int) -> Duration {
        guard failures > 0 else { return policy.interval }
        var schedule = policy.failureBackoff.schedule(using: randomness)
        var chosen = policy.interval
        for _ in 0..<failures {
            chosen = schedule.next()
        }
        return chosen
    }

    private func request(after delay: Duration) -> BackgroundRefreshRequest {
        BackgroundRefreshRequest(
            identifier: policy.identifier,
            kind: policy.kind,
            earliestBeginDate: now().addingTimeInterval(delay.seconds)
        )
    }

    /// Submits and logs a rejection rather than throwing it.
    ///
    /// Every caller of this is inside `handle()`, where there is nobody to
    /// throw to: the system has launched the app in the background, and the
    /// only honest responses to "the scheduler refused the request" are to
    /// record it and to let the outcome still be reported. The explicit
    /// `scheduleNext()` above is the path that propagates.
    private func submit(after delay: Duration, reason: String) {
        do {
            try scheduler.submit(request(after: delay))
        } catch {
            let message = "Could not schedule the next refresh (\(reason)): \(error.localizedDescription)"
            logger.error("\(message, privacy: .public)")
        }
    }
}

// MARK: - Duration as an interval

/// `Date` arithmetic is in `TimeInterval` and the policy is in `Duration`, so
/// one of them has to convert.
///
/// `Backoff` carries its own `fileprivate` copy of this. It is left there
/// rather than hoisted into a shared extension, because widening it would be a
/// change to a type this item does not otherwise touch, and the conversion is
/// four lines whose correctness is local.
private extension Duration {
    /// This duration as a count of seconds.
    ///
    /// `components` is exact — `attoseconds` is an integer count — so the only
    /// loss is `Double`'s significand, which on a six-hour cap is nanoseconds.
    var seconds: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) * 1e-18
    }
}
