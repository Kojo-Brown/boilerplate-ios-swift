import Foundation
import Testing
import os

/// Polls an asynchronous condition until it holds, or fails the test.
///
/// The structured-concurrency suites all need the same ordering fact before they
/// can assert anything: the work under test must have reached a particular point
/// — every child started, this one child finished — before the test does the
/// next thing. A fixed `Task.sleep` would only make that *likely*, and the
/// margin it needs is exactly the margin that makes the suite slow on a laptop
/// and flaky on a loaded CI runner. Polling turns the assumption into a fact and
/// costs nothing once it is already true.
///
/// Named `AsyncPoll.until` rather than a free `waitUntil` on purpose:
/// `LatestOnlyTaskTests` has a `@MainActor` helper of that name taking a
/// synchronous condition, and a synchronous closure converts implicitly to an
/// asynchronous one, so a second overload would make the calls there ambiguous.
enum AsyncPoll {
    /// Returns once `condition` is true. Fails the test if `timeout` elapses first.
    /// - Parameter description: Typed as `Comment` rather than `String` because
    ///   that is what `#require` takes, and `Comment` is only
    ///   `ExpressibleByStringLiteral` — a `String` *variable* does not convert.
    static func until(
        _ description: Comment = "the polled condition never held",
        timeout: Duration = .seconds(10),
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            if try await condition() { return }
            try #require(ContinuousClock.now < deadline, description)
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Counts how many pieces of work are in flight at once, and remembers the most
/// there ever were.
///
/// This is how "at most `maxConcurrent` at a time" stops being a claim in a doc
/// comment. `peak` is the number the bounded and unbounded spellings disagree
/// on; `inFlight` returning to zero is how a test says that nothing outlived the
/// call it belonged to.
actor ConcurrencyProbe {
    /// The largest number ever inside at one moment.
    private(set) var peak = 0
    /// How many are inside right now.
    private(set) var inFlight = 0
    /// How many have ever entered — the count that shows a cancelled group
    /// stopped refilling its window rather than working through the backlog.
    private(set) var started = 0

    func enter() {
        started += 1
        inFlight += 1
        peak = max(peak, inFlight)
    }

    func leave() {
        inFlight -= 1
    }
}

/// Runs `work` inside `probe`, leaving on the way out whether it returns or throws.
///
/// A `defer` cannot `await`, so the two exits are written out. Both matter: the
/// cancellation tests are precisely the ones where `work` throws, and a probe
/// that only decremented on success would report phantom work still in flight.
func tracked<Value>(
    in probe: ConcurrencyProbe,
    _ work: () async throws -> Value
) async throws -> Value {
    await probe.enter()
    do {
        let value = try await work()
        await probe.leave()
        return value
    } catch {
        await probe.leave()
        throw error
    }
}

/// A barrier that releases work by name, so a test can *choose* the order things
/// finish in instead of inferring it from sleeps.
///
/// Ordering assertions written with sleeps are the ones that pass for a year and
/// then fail on a busy runner. Here the test opens index 3, waits for the
/// collector to record a result, opens index 2, and so on: the completion order
/// is driven rather than raced, so "results came back in completion order" and
/// "results came back in input order" are distinguishable with no timing margin
/// at all.
actor TaskGate {
    private var arrived: Set<Int> = []
    private var opened: Set<Int> = []

    /// How many pieces of work have reached the gate. With an unbounded fan-out
    /// this reaches the element count; with a bounded one it stops at the window.
    var arrivedCount: Int { arrived.count }

    /// Bumped by whoever is collecting results, so a test can wait for a result
    /// to have been *taken* rather than merely produced.
    private(set) var collectedCount = 0

    func open(_ index: Int) {
        opened.insert(index)
    }

    /// Whether `index` has been released yet.
    ///
    /// For work that has to keep doing something *while* it waits — checking its
    /// own cancellation, say — rather than only waiting. Those callers own their
    /// loop and ask the gate each time round instead of parking inside
    /// `waitForOpening(at:)`.
    func isOpen(_ index: Int) -> Bool {
        opened.contains(index)
    }

    func collect() {
        collectedCount += 1
    }

    /// Announces arrival at `index`, then waits there until `index` is opened.
    ///
    /// The wait polls rather than parking on a continuation because the actor
    /// releases at every `Task.sleep`, which is what lets `open(_:)` and
    /// `arrivedCount` get in while callers are waiting here.
    func waitForOpening(at index: Int) async throws {
        arrived.insert(index)
        while !opened.contains(index) {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// `waitForOpening(at:)` for a caller that must survive its own cancellation.
    ///
    /// A test that wants to reach code with `Task.isCancelled` *already* true has
    /// to park the task somewhere first, cancel it, and only then let it
    /// through — and a parking spot that rethrows the cancellation would report
    /// it from the wrong place. `try?` makes this the one wait that does not.
    ///
    /// After cancellation `Task.sleep` returns immediately, so the loop spins
    /// until the release lands. That is deliberate and lasts microseconds: the
    /// only caller opens the gate on the line after it cancels.
    func waitForOpeningIgnoringCancellation(at index: Int) async {
        arrived.insert(index)
        while !opened.contains(index) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A counter that a synchronous, non-isolated callback can bump.
///
/// The callback-bridging tests are driven from `@Sendable` closures with no
/// `await` available, so an actor is the wrong shape: `await counter.record()`
/// cannot be written inside `start`. The state lives *inside* the lock rather
/// than beside it, which is what lets this be `Sendable` by the compiler's own
/// reckoning instead of by assertion — see `docs/concurrency.md`.
final class LockedCounter: Sendable {
    private let recorded = OSAllocatedUnfairLock(initialState: 0)

    /// Named `calls` rather than `count` deliberately. SwiftLint's `empty_count`
    /// rule rewrites every `something.count == 0` into `something.isEmpty`, and a
    /// counter has no such thing — "it was never called" *is* a comparison to
    /// zero, and it is the assertion these tests are made of.
    var calls: Int { recorded.withLock { $0 } }

    func increment() {
        recorded.withLock { $0 += 1 }
    }
}

/// Holds the completion callback a bridged API was handed, so a test can invoke
/// it whenever it chooses — including at the moments that are hardest to reach:
/// after cancellation, and twice.
final class FinishBox<Value: Sendable>: Sendable {
    typealias Finish = @Sendable (Result<Value, any Error>) -> Void

    private let stored = OSAllocatedUnfairLock<Finish?>(initialState: nil)

    /// Whether the code under test has handed over its callback yet.
    var isStored: Bool { stored.withLock { $0 != nil } }

    func store(_ finish: @escaping Finish) {
        stored.withLock { $0 = finish }
    }

    /// Reports `result` through the stored callback. Does nothing if there is none.
    func finish(_ result: Result<Value, any Error>) {
        let callback = stored.withLock { $0 }
        callback?(result)
    }
}

/// Records that a child observed its own cancellation.
actor CancellationWitness {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
