import Foundation
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

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
        let gate = TaskGate()
        let witness = CancellationWitness()
        let returned = LockedCounter()

        let call = Task {
            defer { returned.increment() }
            try await withTimeout(.milliseconds(50)) {
                await Self.parkIgnoringCancellation(until: gate, noticing: witness)
            }
        }

        // Cancellation reaching the operation is the deadline firing, observed
        // rather than timed: `withTimeout` cancels the group only after
        // `next()` has handed it a result, and a parked operation cannot be
        // that result. So this poll returning means the sleeper won.
        try await AsyncPoll.until("the operation never observed cancellation") {
            await witness.count == 1
        }

        // The whole finding, and now a fact rather than a floor on a stopwatch:
        // the deadline has passed, the operation has been told to stop, and the
        // call has *still* not returned — because a task group waits for its
        // children and this one will not stop until the gate opens. That is
        // what bounding an uncancellable operation costs.
        #expect(returned.calls == 0)

        await gate.open(0)

        // And when it finally does return, it reports the deadline it could not
        // enforce.
        await #expect(throws: TimedOutError.self) {
            try await call.value
        }
        #expect(returned.calls == 1)
    }

    /// Waits for `gate` without ever letting cancellation out, recording in
    /// `witness` the first time it notices it has been cancelled.
    ///
    /// Stands in for the callback-based APIs this package bridges: a task parked
    /// on a delegate callback has no suspension point for cancellation to be
    /// delivered to, so it runs to completion regardless. `try?` is what makes
    /// this loop that — after cancellation `Task.sleep` returns immediately, so
    /// it spins rather than sleeps, which is deliberate and lasts only until the
    /// caller opens the gate on the line after it asserts.
    ///
    /// This replaces a fixed 600ms burn under a 100ms deadline, which asserted
    /// `elapsed > 400ms` and read as a 6× margin. It was not one. The claim
    /// needs the sleeping child to win a race against a cooperative loop, and on
    /// run #49 it lost: the operation ran its full 600ms, `next()` handed back
    /// *its* value, and the call returned no error at all on a runner where 400+
    /// tests share a small cooperative pool and a 100ms timer's continuation can
    /// be scheduled late. Driving the ordering removes the race rather than
    /// widening the margin — and asserts more than the elapsed time could, since
    /// "had not returned yet at the moment cancellation landed" is the actual
    /// caveat, where a stopwatch reading only implied it.
    private static func parkIgnoringCancellation(
        until gate: TaskGate,
        noticing witness: CancellationWitness
    ) async {
        var noticed = false
        while true {
            if await gate.isOpen(0) { return }
            if !noticed, Task.isCancelled {
                noticed = true
                await witness.record()
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
