import Foundation
import Testing
@testable import BoilerplateiOSSwift

// MARK: - Test helpers

private enum SampleFailure: Error, Equatable {
    case boom
}

/// Waits until `condition` holds, or fails the test.
///
/// Every superseding test below needs one ordering fact: the run being
/// superseded must have claimed its ticket before the superseding run claims
/// the next one. A fixed `Task.sleep` would only make that *likely* — the first
/// run lives in its own `Task`, which cannot start until the main actor is free,
/// and Swift Testing runs suites in parallel, so how many main-actor jobs are
/// queued ahead of it is not this test's to know. Polling `isRunning` turns the
/// assumption into a fact and costs nothing when it is already true.
@MainActor
private func waitUntil(
    _ condition: @MainActor () -> Bool,
    timeout: Duration = .seconds(5)
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        try #require(
            ContinuousClock.now < deadline,
            "the run under test never reached its suspension point"
        )
        try await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - Tests

/// The hop back onto the main actor: what may land, and what must not.
@Suite("LatestOnlyTask")
struct LatestOnlyTaskTests {

    // MARK: The uncontended path

    @Test("a run with nothing to supersede returns its value")
    @MainActor
    func singleRunReturnsItsValue() async throws {
        let latest = LatestOnlyTask<Int>()

        let value = try await latest.run { 7 }

        #expect(value == 7)
        #expect(!latest.isRunning)
    }

    @Test("the operation runs off the main actor")
    @MainActor
    func operationRunsOffTheMainActor() async throws {
        let latest = LatestOnlyTask<Bool>()

        let ranOffMain = try await latest.run { !Thread.isMainThread }

        #expect(ranOffMain == true)
    }

    @Test("isRunning reports the newest run, and clears when it finishes")
    @MainActor
    func isRunningTracksTheNewestRun() async throws {
        let latest = LatestOnlyTask<String>()
        #expect(!latest.isRunning)

        let running = Task { @MainActor in
            try await latest.run {
                try await Task.sleep(for: .milliseconds(150))
                return "done"
            }
        }
        try await waitUntil { latest.isRunning }
        #expect(latest.isRunning)

        let value = try await running.value

        #expect(value == "done")
        #expect(!latest.isRunning)
    }

    // MARK: Superseding — the reason the type exists

    @Test("a superseded run reports nil and the newest run's value wins")
    @MainActor
    func supersededRunReportsNil() async throws {
        let latest = LatestOnlyTask<String>()

        let first = Task { @MainActor in
            try await latest.run {
                try await Task.sleep(for: .milliseconds(400))
                return "first"
            }
        }
        try await waitUntil { latest.isRunning }

        let second = try await latest.run { "second" }
        let firstResult = try await first.value

        #expect(second == "second")
        #expect(firstResult == nil)
    }

    @Test("a result that ignores cancellation is still discarded once superseded")
    @MainActor
    func staleResultIsDiscardedWhenCancellationIsIgnored() async throws {
        let latest = LatestOnlyTask<String>()

        let first = Task { @MainActor in
            try await latest.run {
                // Written to ignore cancellation outright: `Task.yield()` does
                // not throw, and nothing here reads `Task.isCancelled`. This is
                // the third-party SDK, or the request already past its last
                // cancellation point, that runs to completion whatever is asked
                // of it — and then hands back a perfectly good, entirely stale
                // answer.
                //
                // Cancelling the superseded run is therefore a request, not a
                // guarantee, which is why the generation ticket rather than
                // `Task.isCancelled` is what decides who may deliver.
                let deadline = ContinuousClock.now + .milliseconds(250)
                while ContinuousClock.now < deadline {
                    await Task.yield()
                }
                return "stale"
            }
        }
        try await waitUntil { latest.isRunning }

        let second = try await latest.run { "fresh" }
        let firstResult = try await first.value

        #expect(second == "fresh")
        #expect(firstResult == nil)
    }

    @Test("a superseded run that fails does not throw at its caller")
    @MainActor
    func supersededFailureIsNotRethrown() async throws {
        let latest = LatestOnlyTask<Int>()

        let failing = Task { @MainActor in
            try await latest.run {
                // `try?` so the sleep survives cancellation and the throw below
                // is reached: the point under test is a superseded *failure*,
                // not a superseded cancellation.
                try? await Task.sleep(for: .milliseconds(250))
                throw SampleFailure.boom
            }
        }
        try await waitUntil { latest.isRunning }

        let current = try await latest.run { 42 }
        let supersededResult = try await failing.value

        #expect(current == 42)
        #expect(supersededResult == nil)
    }

    // MARK: Errors and cancellation on the current run

    @Test("an error from the current run reaches its caller")
    @MainActor
    func errorFromTheCurrentRunIsRethrown() async {
        let latest = LatestOnlyTask<Int>()

        await #expect(throws: SampleFailure.boom) {
            try await latest.run { throw SampleFailure.boom }
        }

        #expect(!latest.isRunning)
    }

    @Test("cancel discards the run in flight")
    @MainActor
    func cancelDiscardsTheRunInFlight() async throws {
        let latest = LatestOnlyTask<String>()

        let running = Task { @MainActor in
            try await latest.run {
                try await Task.sleep(for: .seconds(5))
                return "never"
            }
        }
        try await waitUntil { latest.isRunning }
        #expect(latest.isRunning)

        latest.cancel()
        let result = try await running.value

        // Cancelled reads the same as superseded to the caller: nil, not a
        // thrown `CancellationError`. There is nothing for it to do either way.
        #expect(result == nil)
        #expect(!latest.isRunning)
    }

    @Test("a run started after cancel is unaffected by it")
    @MainActor
    func cancelDoesNotPoisonLaterRuns() async throws {
        let latest = LatestOnlyTask<Int>()
        latest.cancel()

        let value = try await latest.run { 3 }

        #expect(value == 3)
    }
}
