import Foundation
import Testing
@testable import BoilerplateiOSSwift

private enum TimeoutFailure: Error, Equatable {
    case boom
}

/// What a deadline does, and — the part the name oversells — what it does not.
@Suite("withTimeout", .serialized, .timeLimit(.minutes(1)))
struct TimeoutTests {

    // MARK: The race

    @Test("an operation that finishes in time returns its value without waiting")
    func aSuccessDoesNotWaitOutTheBudget() async throws {
        let clock = ContinuousClock()
        let start = clock.now

        // The budget is deliberately enormous, and that is the whole point.
        // What this test asks is whether the success path abandons the pending
        // sleeper or waits for it. `withTimeout` has no `Clock` seam — SPEC.md
        // Phase 7 records that gap — so the only honest way to ask it is to
        // make "waited for it" a duration nothing else could be mistaken for.
        //
        // It was `.seconds(30)` against a `< .seconds(5)` bound, a ratio of 6,
        // and a loaded runner forged a failure through it on run #48 of the
        // DI-container branch: 16.48s elapsed on a call that had in fact
        // returned immediately — not the 30s the bug produces, just scheduling
        // starvation in a suite that runs 400+ tests at once. Main's own last
        // green run spent 7.6s inside this test against that 5s bound, so the
        // margin was already nearly gone before anything was added to it.
        let value = try await withTimeout(.seconds(3600)) { 7 }
        let elapsed = clock.now - start

        // Without `cancelAll()` on the success path the group would still be
        // holding a pending sleeper, would wait for it, and this would take an
        // hour — a bug that is invisible in review and unmistakable in
        // production. It now fails two ways rather than one: this expectation,
        // and the suite's own `.timeLimit(.minutes(1))`, which no hour-long
        // wait can survive and which reports by name rather than by margin.
        #expect(value == 7)
        #expect(elapsed < .seconds(30))
    }

    @Test("an operation that overruns throws TimedOutError and is cancelled")
    func anOverrunTimesOutAndCancelsTheOperation() async throws {
        let witness = CancellationWitness()

        let thrown = await #expect(throws: TimedOutError.self) {
            try await withTimeout(.milliseconds(100)) {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await witness.record()
                    throw error
                }
            }
        }

        #expect(thrown?.duration == Duration.milliseconds(100))
        // The operation did not merely stop being awaited: it was cancelled, and
        // being suspended on a cancellable `Task.sleep` it found out at once.
        #expect(await witness.count == 1)
    }

    @Test("an operation that fails first reports its own error, not a timeout")
    func anEarlyFailurePropagatesUnchanged() async {
        await #expect(throws: TimeoutFailure.boom) {
            try await withTimeout(.seconds(30)) { () -> Int in
                throw TimeoutFailure.boom
            }
        }
    }

    @Test("cancelling the caller reports cancellation, not a timeout")
    func outerCancellationIsDistinctFromTimingOut() async throws {
        let started = LockedCounter()

        let task = Task {
            try await withTimeout(.seconds(30)) {
                started.increment()
                try await Task.sleep(for: .seconds(30))
            }
        }

        try await AsyncPoll.until("the operation never started") {
            started.calls == 1
        }
        task.cancel()

        // Two failures are being distinguished here: the deadline passing and
        // the caller losing interest. They arrive through the same group and
        // must not be collapsed into one error, because only one of them is
        // worth retrying.
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("a caller that is already cancelled does not report a timeout")
    func anAlreadyCancelledCallerIsNotReportedAsATimeout() async throws {
        let gate = TaskGate()

        let task = Task {
            // Park until this task has been cancelled, so `withTimeout` is
            // entered with cancellation already pending and both of its
            // children are born cancelled.
            await gate.waitForOpeningIgnoringCancellation(at: 0)
            return try await withTimeout(.seconds(30)) {
                // Checked rather than assumed: an operation that ignores
                // cancellation would return 7 and win the race, which would
                // make this test about scheduling luck instead of about the
                // choice of `addTask`.
                try Task.checkCancellation()
                return 7
            }
        }

        try await AsyncPoll.until("the task never reached the gate") {
            await gate.arrivedCount == 1
        }
        task.cancel()
        await gate.open(0)

        // `addTaskUnlessCancelled` here would decline both children and leave
        // `next()` with nothing to hand back; `addTask` starts them cancelled,
        // so the sleeper throws `CancellationError` immediately and that is
        // what the caller sees.
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("nothing the timeout started is still running when it returns")
    func nothingOutlivesTheCall() async throws {
        let probe = ConcurrencyProbe()

        await #expect(throws: TimedOutError.self) {
            try await withTimeout(.milliseconds(100)) {
                try await tracked(in: probe) {
                    try await Task.sleep(for: .seconds(30))
                }
            }
        }

        #expect(await probe.started == 1)
        #expect(await probe.inFlight == 0)
    }

    // MARK: The limit the name hides

    @Test("the deadline bounds the wait only as far as the operation is cancellable")
    func anUncancellableOperationOutlastsItsOwnDeadline() async throws {
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: TimedOutError.self) {
            try await withTimeout(.milliseconds(100)) {
                await Self.workIgnoringCancellation(for: .milliseconds(600))
            }
        }

        let elapsed = clock.now - start

        // Compiled and run rather than described, for the reason
        // `ConcurrentMapTests` keeps its unbounded task group: a caveat nothing
        // executes is folklore. A 100ms deadline over a 600ms operation that
        // never checks for cancellation returns in 600ms, with a
        // `TimedOutError` faithfully reporting a deadline it could not enforce.
        //
        // The number is asserted from below only. It is a floor on how long an
        // uncancellable operation makes the caller wait, and CI load can only
        // push it up.
        #expect(elapsed > .milliseconds(400))
    }

    /// Burns `duration` of wall clock without ever observing cancellation.
    ///
    /// Stands in for the callback-based APIs this package bridges: a task parked
    /// on a delegate callback has no suspension point for cancellation to be
    /// delivered to, so it runs to completion regardless. `try?` is what makes
    /// this loop that — after cancellation `Task.sleep` returns immediately, so
    /// it spins rather than sleeps, which is deliberate and lasts 600ms.
    private static func workIgnoringCancellation(for duration: Duration) async {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
