import Foundation
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

// MARK: - The spelling this type exists to replace

private enum SampleFailure: Error, Equatable {
    case boom
}

/// The task group written the way it is usually written first: every child added
/// up front, results appended as `next()` yields them.
///
/// It is kept compiled and run rather than quoted in a doc comment, for the same
/// reason `SingleFlightCacheTests` keeps its naive actor: a pitfall nothing
/// executes is folklore, and folklore stops being true without telling anyone.
/// The two tests below run this and `ConcurrentMap.over` through *identical*
/// gates and get different answers.
private func unboundedCompletionOrderMap<Element: Sendable, Transformed: Sendable>(
    _ elements: [Element],
    onCollect: @escaping @Sendable () async -> Void = {},
    transform: @escaping @Sendable (Element) async throws -> Transformed
) async throws -> [Transformed] {
    try await withThrowingTaskGroup(of: Transformed.self) { group in
        // Every child is runnable the moment it is added. Nothing here is a
        // queue, and nothing paces it.
        for element in elements {
            group.addTask { try await transform(element) }
        }

        var results: [Transformed] = []
        for try await value in group {
            results.append(value)
            await onCollect()
        }
        return results
    }
}

// MARK: - Tests

/// Bounded fan-out, stable ordering, and the guarantee that nothing outlives the
/// call.
@Suite("ConcurrentMap", .serialized)
struct ConcurrentMapTests {

    // MARK: Ordering

    @Test("an empty input does no work and returns nothing")
    func emptyInputReturnsEmpty() async throws {
        let probe = ConcurrencyProbe()

        let results = try await ConcurrentMap.over([Int](), maxConcurrent: 4) { value in
            try await tracked(in: probe) { value * 2 }
        }

        #expect(results.isEmpty)
        #expect(await probe.started == 0)
    }

    @Test("results come back in input order, whatever order they finish in")
    func preservesInputOrder() async throws {
        let gate = TaskGate()
        let labels = ["a", "b", "c", "d"]

        let mapping = Task {
            try await ConcurrentMap.over(Array(labels.indices), maxConcurrent: labels.count) { index in
                try await gate.waitForOpening(at: index)
                return labels[index]
            }
        }

        // Finish them in reverse. The window is the whole input here, so all
        // four are waiting at the gate and the completion order is the test's
        // to choose rather than the scheduler's to decide.
        try await AsyncPoll.until("all four children reached the gate") {
            await gate.arrivedCount == labels.count
        }
        for index in labels.indices.reversed() {
            await gate.open(index)
        }

        let ordered = try await mapping.value
        #expect(ordered == labels)
    }

    @Test("the unbounded spelling returns them in completion order instead")
    func theNaiveSpellingScramblesTheOrder() async throws {
        let gate = TaskGate()
        let labels = ["a", "b", "c", "d"]

        let mapping = Task {
            try await unboundedCompletionOrderMap(
                Array(labels.indices),
                onCollect: { await gate.collect() }
            ) { index in
                try await gate.waitForOpening(at: index)
                return labels[index]
            }
        }

        try await AsyncPoll.until("all four children reached the gate") {
            await gate.arrivedCount == labels.count
        }

        // Release one at a time and wait for each result to have been *taken*
        // before releasing the next, so the collection order is driven rather
        // than raced. No sleep, and therefore no margin to get wrong.
        for (collected, index) in labels.indices.reversed().enumerated() {
            await gate.open(index)
            try await AsyncPoll.until("a released result was never collected") {
                await gate.collectedCount == collected + 1
            }
        }

        let byCompletion = try await mapping.value
        #expect(byCompletion == ["d", "c", "b", "a"])
    }

    // MARK: The concurrency ceiling

    @Test("never more than maxConcurrent are in flight")
    func neverExceedsTheCeiling() async throws {
        let probe = ConcurrencyProbe()

        let results = try await ConcurrentMap.over(Array(1...12), maxConcurrent: 3) { value in
            try await tracked(in: probe) {
                try await Task.sleep(for: .milliseconds(30))
                return value * 2
            }
        }

        #expect(results == Array(1...12).map { $0 * 2 })
        #expect(await probe.peak == 3)
        #expect(await probe.started == 12)
        #expect(await probe.inFlight == 0)
    }

    @Test("the unbounded spelling starts all twelve at once")
    func theNaiveSpellingStartsEverythingAtOnce() async throws {
        let probe = ConcurrencyProbe()

        let results = try await unboundedCompletionOrderMap(Array(1...12)) { value in
            try await tracked(in: probe) {
                try await Task.sleep(for: .milliseconds(30))
                return value * 2
            }
        }

        #expect(results.count == 12)
        // The number that makes the point: same work, same fixtures, four times
        // the peak. At 500 URLs it is 500 sockets.
        #expect(await probe.peak == 12)
    }

    @Test("a ceiling of one runs them one at a time")
    func aCeilingOfOneIsSequential() async throws {
        let probe = ConcurrencyProbe()

        let results = try await ConcurrentMap.over(Array(1...5), maxConcurrent: 1) { value in
            try await tracked(in: probe) {
                try await Task.sleep(for: .milliseconds(5))
                return value
            }
        }

        #expect(results == Array(1...5))
        #expect(await probe.peak == 1)
    }

    @Test("every element is transformed exactly once")
    func everyElementIsTransformedOnce() async throws {
        let probe = ConcurrencyProbe()

        let results = try await ConcurrentMap.over(Array(1...25), maxConcurrent: 4) { value in
            try await tracked(in: probe) { value * value }
        }

        #expect(results == Array(1...25).map { $0 * $0 })
        #expect(await probe.started == 25)
    }

    // MARK: Errors — structured means the group waits

    @Test("the first error propagates and no sibling outlives the call")
    func errorPropagatesAndNothingOutlivesTheCall() async throws {
        let probe = ConcurrencyProbe()

        await #expect(throws: SampleFailure.boom) {
            try await ConcurrentMap.over(Array(0..<8), maxConcurrent: 8) { value in
                try await tracked(in: probe) {
                    guard value != 3 else {
                        try await Task.sleep(for: .milliseconds(20))
                        throw SampleFailure.boom
                    }
                    // Long enough that every sibling is still in flight when
                    // element 3 throws, so the assertion below is about the
                    // group awaiting them rather than about them being quick.
                    try await Task.sleep(for: .seconds(30))
                    return value
                }
            }
        }

        // The point of structured concurrency, in one assertion. `over` has
        // returned, and there is no child of it still running anywhere: the
        // group cancelled the siblings and *awaited* them before letting the
        // error out. A `for` loop of `Task { }` would have returned with seven
        // 30-second sleeps still going.
        #expect(await probe.inFlight == 0)
    }

    // MARK: Cancellation propagation

    @Test("cancelling the caller stops the window being refilled")
    func cancellationStopsTheWindowBeingRefilled() async throws {
        let probe = ConcurrencyProbe()

        let mapping = Task {
            try await ConcurrentMap.over(Array(0..<6), maxConcurrent: 2) { value in
                try await tracked(in: probe) {
                    try await Task.sleep(for: .seconds(30))
                    return value
                }
            }
        }

        try await AsyncPoll.until("the window never filled") {
            await probe.inFlight == 2
        }
        mapping.cancel()

        await #expect(throws: CancellationError.self) {
            try await mapping.value
        }

        // Two started, four never did. That is `addTaskUnlessCancelled` doing
        // its job: a child added to a cancelled group is born cancelled, and a
        // transform that never checks for cancellation would run to completion
        // regardless, so declining to add it is the only way not to start it.
        #expect(await probe.started == 2)
        #expect(await probe.inFlight == 0)
    }

    @Test("children observe the cancellation, and what they finished still returns")
    func cancellationReachesChildrenAndFinishedWorkSurvives() async throws {
        let probe = ConcurrencyProbe()
        let witness = CancellationWitness()

        let mapping = Task {
            try await ConcurrentMap.over(Array(0..<2), maxConcurrent: 2) { value in
                try await tracked(in: probe) {
                    // Deliberately not `try await`: the sleep's cancellation is
                    // swallowed so the child *chooses* what to do about being
                    // cancelled, which is the whole of what cooperative
                    // cancellation means.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    await witness.record()
                    return value * 10
                }
            }
        }

        try await AsyncPoll.until("both children never started") {
            await probe.inFlight == 2
        }
        mapping.cancel()

        // Both children saw it — that is the propagation. Neither threw, so both
        // produced a value, and `over` hands back the work that was already paid
        // for rather than discarding it because a cancellation arrived late.
        let results = try await mapping.value
        #expect(results == [0, 10])
        #expect(await witness.count == 2)
    }
}
