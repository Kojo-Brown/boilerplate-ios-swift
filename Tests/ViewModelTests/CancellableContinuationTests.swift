import Foundation
import Testing
@testable import BoilerplateiOSSwift

private enum BridgeFailure: Error, Equatable {
    case boom
}

/// Bridging a callback API into `async` *with* cancellation: every
/// interleaving that matters, each one driven rather than raced.
///
/// Every test here reaches its moment through `FinishBox`, which holds the
/// callback the bridge handed out so the test can fire it whenever it likes.
/// That is what makes "the callback arrives after cancellation" a test rather
/// than a hope — it is a race that a sleep-based test would reproduce on maybe
/// one run in fifty, and it is the one that traps rather than merely returning
/// the wrong answer.
@Suite("CancellableContinuation", .serialized)
struct CancellableContinuationTests {

    // MARK: The uncontended paths

    @Test("work that finishes inside start returns its value and leaves nothing to cancel")
    func synchronousCompletionNeedsNoHandle() async throws {
        let cancels = LockedCounter()

        let value: Int = try await CancellableContinuation.run { finish in
            finish(.success(5))
            return { cancels.increment() }
        }

        #expect(value == 5)
        // The handle arrived after the work was already done, so it was dropped
        // rather than stored for a cancellation that can no longer come.
        #expect(cancels.count == 0)
    }

    @Test("a callback that arrives later is delivered")
    func deliversACallbackThatArrivesLater() async throws {
        let finisher = FinishBox<String>()

        let bridged = Task {
            try await CancellableContinuation.run { finish in
                finisher.store(finish)
                return {}
            }
        }
        try await AsyncPoll.until("the bridge never handed over its callback") {
            finisher.isStored
        }
        finisher.finish(.success("later"))

        let value = try await bridged.value
        #expect(value == "later")
    }

    @Test("an error reported by the callback reaches the caller")
    func throwsTheErrorTheCallbackReported() async throws {
        let finisher = FinishBox<Int>()

        let bridged = Task {
            try await CancellableContinuation.run { finish in
                finisher.store(finish)
                return {}
            }
        }
        try await AsyncPoll.until("the bridge never handed over its callback") {
            finisher.isStored
        }
        finisher.finish(.failure(BridgeFailure.boom))

        await #expect(throws: BridgeFailure.boom) {
            try await bridged.value
        }
    }

    @Test("a second callback is ignored")
    func aSecondCallbackIsIgnored() async throws {
        let finisher = FinishBox<Int>()

        let bridged = Task {
            try await CancellableContinuation.run { finish in
                finisher.store(finish)
                return {}
            }
        }
        try await AsyncPoll.until("the bridge never handed over its callback") {
            finisher.isStored
        }

        finisher.finish(.success(1))
        // A callback API that reports twice is a bug in that API, and one this
        // bridge must survive rather than propagate: resuming a continuation
        // twice traps the process. Only the first report is delivered.
        finisher.finish(.success(2))

        let value = try await bridged.value
        #expect(value == 1)
    }

    // MARK: Cancellation

    @Test("cancelling throws and stops the underlying work")
    func cancellingThrowsAndStopsTheWork() async throws {
        let finisher = FinishBox<Int>()
        let cancels = LockedCounter()

        let bridged = Task {
            try await CancellableContinuation.run { finish in
                finisher.store(finish)
                return { cancels.increment() }
            }
        }
        try await AsyncPoll.until("the bridge never handed over its callback") {
            finisher.isStored
        }
        bridged.cancel()

        await #expect(throws: CancellationError.self) {
            try await bridged.value
        }
        // The half a bare `withCheckedThrowingContinuation` cannot do: the
        // underlying API was told to stop. Exactly once — `onCancel` takes the
        // handle out of the state as it uses it.
        #expect(cancels.count == 1)
    }

    @Test("a callback arriving after cancellation is dropped rather than resumed twice")
    func aLateCallbackAfterCancellationIsDropped() async throws {
        let finisher = FinishBox<Int>()
        let cancels = LockedCounter()

        let bridged = Task {
            try await CancellableContinuation.run { finish in
                finisher.store(finish)
                return { cancels.increment() }
            }
        }
        try await AsyncPoll.until("the bridge never handed over its callback") {
            finisher.isStored
        }
        bridged.cancel()

        await #expect(throws: CancellationError.self) {
            try await bridged.value
        }

        // The API acknowledges on its own schedule, well after the caller has
        // given up — which is ordinary, not broken. This line is the one that
        // would crash the test process against a bridge that had kept the
        // continuation: `CheckedContinuation` traps on a second resume.
        finisher.finish(.success(99))

        #expect(cancels.count == 1)
    }

    @Test("a task cancelled before it reaches the bridge never starts the work")
    func anAlreadyCancelledTaskNeverStartsTheWork() async throws {
        let gate = TaskGate()
        let starts = LockedCounter()

        let bridged = Task {
            // Park here so the cancellation below is guaranteed to land before
            // `run` is entered, rather than racing it.
            await gate.waitForOpeningIgnoringCancellation(at: 0)

            // Annotated rather than inferred: nothing else in this closure pins
            // `run`'s generic parameter, and a bare `.success(1)` would leave it
            // to the integer literal's default type.
            let value: Int = try await CancellableContinuation.run { finish in
                starts.increment()
                finish(.success(1))
                return {}
            }
            return value
        }
        try await AsyncPoll.until("the task never parked at the gate") {
            await gate.arrivedCount == 1
        }
        bridged.cancel()
        await gate.open(0)

        await #expect(throws: CancellationError.self) {
            try await bridged.value
        }
        // `withTaskCancellationHandler` runs its handler immediately when the
        // task is already cancelled — before the operation body. There was no
        // continuation for it to resume, so the body resumed itself and never
        // called `start`. Work that has not begun does not need cancelling; the
        // bug this rules out is the body missing it and hanging forever,
        // because nothing will call the handler a second time.
        #expect(starts.count == 0)
    }
}
