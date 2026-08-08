import Foundation
import Testing
import os
@testable import BoilerplateiOSSwift

// MARK: - Helpers

/// Records the terminations a stream reported, from the synchronous, unisolated
/// callback that reports them.
///
/// An actor is the wrong shape here for the same reason `LockedCounter` is not
/// one: the handler is a `@Sendable` closure with no `await` available inside it.
/// The state lives inside the lock rather than beside it, so this is `Sendable`
/// by the compiler's reckoning — see `docs/concurrency.md`.
private final class TerminationLog: Sendable {
    private let entries = OSAllocatedUnfairLock<[DelegateStream<Int>.Termination]>(initialState: [])

    var recorded: [DelegateStream<Int>.Termination] {
        entries.withLock { $0 }
    }

    func record(_ termination: DelegateStream<Int>.Termination) {
        entries.withLock { $0.append(termination) }
    }
}

// MARK: - Tests

/// What each buffering policy keeps, what it throws away, and what happens to a
/// producer whose consumer left.
///
/// Every ordering fact these tests need is arranged rather than raced. A
/// synchronous producer yielding into a stream nobody is draining fills the
/// buffer deterministically, and the two tests that need a consumer *mid-stream*
/// drive it one element at a time through the iterator instead of starting a
/// task and sleeping. There is no timing margin anywhere in here to go bad on a
/// loaded runner.
///
/// The time limit is not a timing assumption; it is the opposite of one. Most of
/// what is asserted here is that a `for await` *ends*, and the failure mode of
/// getting that wrong is a loop that never returns — which, without a limit,
/// reports as a job cancelled at the runner's hour rather than as the test that
/// hung. A minute is two orders of magnitude more than any of these need.
@Suite("DelegateStream", .serialized, .timeLimit(.minutes(1)))
struct DelegateStreamTests {

    // MARK: Buffering policies

    @Test("unbounded buffering keeps every element the consumer has not reached")
    func unboundedKeepsEverything() async {
        let bridge = DelegateStream<Int>(bufferingPolicy: .unbounded)
        let stream = bridge.makeStream()

        for value in 1...5 {
            #expect(bridge.yield(value) == .enqueued)
        }
        bridge.finish()

        var received: [Int] = []
        for await value in stream {
            received.append(value)
        }

        #expect(received == [1, 2, 3, 4, 5])
        #expect(bridge.statistics.enqueued == 5)
        #expect(bridge.statistics.dropped == 0)
        #expect(bridge.statistics.total == 5)
    }

    @Test("newest-wins keeps only the latest element, and counts what it discarded")
    func newestWinsKeepsTheLatest() async {
        let bridge = DelegateStream<Int>(bufferingPolicy: .bufferingNewest(1))
        let stream = bridge.makeStream()

        #expect(bridge.yield(1) == .enqueued)
        for value in 2...5 {
            // The element yielded is the one kept; the drop reported is of the
            // older sample it displaced.
            #expect(bridge.yield(value) == .dropped)
        }
        bridge.finish()

        var received: [Int] = []
        for await value in stream {
            received.append(value)
        }

        #expect(received == [5])
        #expect(bridge.statistics.enqueued == 1)
        #expect(bridge.statistics.dropped == 4)
    }

    @Test("oldest-wins keeps the first arrivals and refuses the rest")
    func oldestWinsKeepsTheFirstArrivals() async {
        let bridge = DelegateStream<Int>(bufferingPolicy: .bufferingOldest(2))
        let stream = bridge.makeStream()

        #expect(bridge.yield(1) == .enqueued)
        #expect(bridge.yield(2) == .enqueued)
        for value in 3...5 {
            #expect(bridge.yield(value) == .dropped)
        }
        bridge.finish()

        var received: [Int] = []
        for await value in stream {
            received.append(value)
        }

        #expect(received == [1, 2])
        #expect(bridge.statistics.enqueued == 2)
        #expect(bridge.statistics.dropped == 3)
    }

    // MARK: The camera's shape

    /// A consumer busy for the next 29 frames comes back to the frame in front
    /// of the camera now. This is the whole reason `CameraService` picks
    /// `.bufferingNewest(1)`.
    @Test("a consumer that falls behind resumes on the newest element")
    func slowConsumerResumesOnTheNewest() async {
        let bridge = DelegateStream<Int>(bufferingPolicy: .bufferingNewest(1))
        let stream = bridge.makeStream()
        var frames = stream.makeAsyncIterator()

        bridge.yield(1)
        let firstTaken = await frames.next()
        #expect(firstTaken == 1)

        // The consumer is off doing a Vision request. The camera does not wait.
        for value in 2...30 {
            bridge.yield(value)
        }

        let nextTaken = await frames.next()
        #expect(nextTaken == 30)
        #expect(bridge.statistics.dropped == 28)
    }

    /// The same consumer, the same producer, the default policy: it is handed a
    /// frame that is 28 frames stale and still has the other 27 to work through.
    ///
    /// Kept compiled and run rather than described, for the reason
    /// `ConcurrentMapTests` keeps its unbounded task group: a pitfall nothing
    /// executes is folklore.
    @Test("the default policy hands that consumer a frame that is 28 frames old")
    func unboundedHandsBackAStaleElement() async {
        let bridge = DelegateStream<Int>(bufferingPolicy: .unbounded)
        let stream = bridge.makeStream()
        var frames = stream.makeAsyncIterator()

        bridge.yield(1)
        let firstTaken = await frames.next()
        #expect(firstTaken == 1)

        for value in 2...30 {
            bridge.yield(value)
        }

        let nextTaken = await frames.next()
        #expect(nextTaken == 2)
        #expect(bridge.statistics.dropped == 0)
        // Twenty-eight frames still queued, each holding its buffer.
        #expect(bridge.statistics.enqueued == 30)
    }

    // MARK: No consumer

    @Test("a producer with no consumer is not a queue")
    func yieldsBeforeAnyStreamAreNotBuffered() async {
        let bridge = DelegateStream<Int>(bufferingPolicy: .unbounded)

        #expect(!bridge.hasConsumer)
        #expect(bridge.yield(1) == .noConsumer)

        let stream = bridge.makeStream()
        #expect(bridge.yield(2) == .enqueued)
        bridge.finish()

        var received: [Int] = []
        for await value in stream {
            received.append(value)
        }

        #expect(received == [2])
        #expect(bridge.statistics.undelivered == 1)
    }

    @Test("finish() ends the consumer's loop, and later elements have nowhere to go")
    func finishEndsTheStream() async {
        let bridge = DelegateStream<Int>(bufferingPolicy: .unbounded)
        let stream = bridge.makeStream()

        bridge.yield(1)
        bridge.finish()

        var received: [Int] = []
        for await value in stream {
            received.append(value)
        }

        // What was already buffered still arrives; the loop then ends.
        #expect(received == [1])
        #expect(!bridge.hasConsumer)
        #expect(bridge.yield(2) == .noConsumer)
        #expect(bridge.statistics.undelivered == 1)
    }

    // MARK: Superseding

    @Test("a second stream supersedes the first rather than splitting elements with it")
    func secondStreamSupersedesTheFirst() async {
        let bridge = DelegateStream<Int>(bufferingPolicy: .unbounded)
        let first = bridge.makeStream()
        bridge.yield(1)

        let second = bridge.makeStream()
        bridge.yield(2)
        bridge.finish()

        var fromFirst: [Int] = []
        for await value in first {
            fromFirst.append(value)
        }
        var fromSecond: [Int] = []
        for await value in second {
            fromSecond.append(value)
        }

        // The superseded stream keeps what it had already been given and then
        // ends. Nothing yielded after the replacement reaches it, and its
        // consumer is not left waiting for something that will never come.
        #expect(fromFirst == [1])
        #expect(fromSecond == [2])
    }

    /// The regression this type's generation counter exists for.
    ///
    /// `CameraService` used to clear its stored continuation from the stream's
    /// termination handler. Both view models call `makeFrameStream()` again on
    /// every `startScanning()`, so the superseded stream's handler ran *after*
    /// the replacement had been installed and cleared it — leaving the delegate
    /// yielding into nothing and the new frame task waiting forever.
    @Test("a superseded stream's termination does not detach the live one")
    func supersededTerminationLeavesTheLiveStreamAttached() async {
        let bridge = DelegateStream<Int>(bufferingPolicy: .unbounded)
        let first = bridge.makeStream()
        let second = bridge.makeStream()

        // Drain the superseded stream to completion, so its termination handler
        // has certainly run before anything below.
        for await _ in first {}

        #expect(bridge.hasConsumer)
        #expect(bridge.yield(1) == .enqueued)
        bridge.finish()

        var received: [Int] = []
        for await value in second {
            received.append(value)
        }
        #expect(received == [1])
    }

    // MARK: Termination handlers

    @Test("finish() reports the stream finished")
    func finishReportsFinished() async {
        let bridge = DelegateStream<Int>(bufferingPolicy: .unbounded)
        let reasons = TerminationLog()
        let stream = bridge.makeStream(onTermination: { reasons.record($0) })

        bridge.finish()
        for await _ in stream {}

        #expect(reasons.recorded == [.finished])
    }

    @Test("cancelling the consuming task reports the stream cancelled")
    func cancellingTheConsumerReportsCancelled() async throws {
        let bridge = DelegateStream<Int>(bufferingPolicy: .unbounded)
        let reasons = TerminationLog()
        let taken = LockedCounter()
        let stream = bridge.makeStream(onTermination: { reasons.record($0) })

        let consumer = Task {
            for await _ in stream {
                taken.increment()
            }
        }

        bridge.yield(1)
        try await AsyncPoll.until("the consumer took the first element") {
            taken.calls == 1
        }

        consumer.cancel()
        await consumer.value

        #expect(reasons.recorded == [.cancelled])
        #expect(!bridge.hasConsumer)
        #expect(bridge.yield(2) == .noConsumer)
    }

    @Test("being superseded is not a termination the first consumer is told about")
    func replacementIsNotReportedAsTermination() async {
        let bridge = DelegateStream<Int>(bufferingPolicy: .unbounded)
        let reasons = TerminationLog()
        let first = bridge.makeStream(onTermination: { reasons.record($0) })

        _ = bridge.makeStream()
        for await _ in first {}

        // The stream ended, but the producer is still wanted — by whoever asked
        // for the replacement. A camera torn down here would race the consumer
        // that just asked for it.
        #expect(reasons.recorded.isEmpty)
    }

    // MARK: Thread safety

    /// The delegate fires from a queue of AVFoundation's choosing, and nothing
    /// serialises it against a view model asking for a new stream. Every yield
    /// must be accounted for exactly once under that.
    ///
    /// A handful of tasks looping, rather than one task per yield: contention on
    /// the lock is what is under test, and a fan-out as wide as the yield count
    /// saturates the cooperative pool and starves whatever suite Swift Testing
    /// is running in parallel with this one.
    @Test("concurrent yields are all accounted for, exactly once")
    func concurrentYieldsAreAccountedFor() async {
        let bridge = DelegateStream<Int>(bufferingPolicy: .unbounded)
        let stream = bridge.makeStream()
        let producers = 4
        let each = 50

        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<producers {
                group.addTask {
                    for offset in 0..<each {
                        bridge.yield(producer * each + offset)
                    }
                }
            }
        }
        bridge.finish()

        var received: Set<Int> = []
        for await value in stream {
            received.insert(value)
        }

        #expect(received.count == producers * each)
        #expect(bridge.statistics.enqueued == producers * each)
        #expect(bridge.statistics.total == producers * each)
    }
}

/// `CameraService` is where the bridge is actually used, and the parts of that
/// wiring which do not need a camera are worth pinning here.
///
/// A simulator has no capture device, so no frame ever arrives — which leaves
/// exactly the properties that matter for the stream's lifecycle: that a second
/// `makeFrameStream()` ends the first rather than stranding its frame task, and
/// that `stop()` ends the live one.
@Suite("CameraService frame stream", .serialized, .timeLimit(.minutes(1)))
struct CameraServiceFrameStreamTests {

    @Test("a service that has captured nothing has counted nothing")
    func freshServiceHasCountedNothing() {
        let service = CameraService()

        #expect(service.frameStatistics.total == 0)
        #expect(service.frameStatistics.dropped == 0)
    }

    @Test("asking for a second frame stream ends the first")
    func secondFrameStreamEndsTheFirst() async {
        let service = CameraService()
        let first = service.makeFrameStream()
        _ = service.makeFrameStream()

        // This is the assertion. Without supersede-and-finish the loop never
        // returns, because the delegate now yields somewhere else and nothing
        // will ever end this stream.
        for await _ in first {}
    }

    @Test("stop() ends the live frame stream")
    func stopEndsTheLiveStream() async {
        let service = CameraService()
        let stream = service.makeFrameStream()

        service.stop()
        for await _ in stream {}
    }
}
