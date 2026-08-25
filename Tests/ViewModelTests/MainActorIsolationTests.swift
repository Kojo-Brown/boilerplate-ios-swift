import Foundation
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

// MARK: - Probes

/// Stands in for a framework callback that is typed `@Sendable` — the shape
/// `ASAuthorizationControllerDelegate` and friends arrive in.
///
/// The `@Sendable` matters: a closure literal formed in a `@MainActor` context
/// and passed to a *non*-`@Sendable` parameter inherits the main actor, so it
/// could touch main-actor state with no ceremony and prove nothing. A
/// `@Sendable` parameter refuses that inference, which is what makes the
/// `MainActor.assumeIsolated` in the test below load-bearing rather than
/// decorative.
private func deliverSynchronously(_ callback: @Sendable () -> Void) {
    callback()
}

/// Task-local state, to show what a detached task does and does not carry.
private enum TraceContext {
    @TaskLocal static var identifier: String = "unset"
}

/// Main-actor-isolated mutable state, reachable only with the main actor's
/// isolation in hand.
@MainActor
private final class MainActorCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

// MARK: - Tests

/// Where code actually runs, measured rather than asserted in prose.
///
/// Every claim here is one a reader would otherwise have to take from the
/// documentation, and two of them are the opposite of what the syntax suggests.
/// They are also version-sensitive: SE-0338 fixed the execution semantics of
/// nonisolated async functions in Swift 5.7, and Swift 6.2's
/// `nonisolated(nonsending)` changes the default again for anyone who adopts it.
/// This suite is what turns "the hop works" from a belief into something that
/// fails a build.
///
/// `CurrentThread.isMain` is the probe throughout — see that type for why the
/// question has to be asked from a synchronous function, and what it does and
/// does not tell you.
@Suite("@MainActor isolation and hops", .serialized)
struct MainActorIsolationTests {

    // MARK: What does not leave the main actor

    @Test("Task { } written on the main actor keeps its body on the main actor")
    @MainActor
    func taskLiteralInheritsTheMainActor() async {
        #expect(CurrentThread.isMain)

        // The single most common way to believe work has been moved off the
        // main thread. `Task.init` marks its operation `@_inheritActorContext`,
        // so a closure literal written here is `@MainActor`-isolated. What this
        // buys is concurrency with respect to the *caller*, not the main thread.
        let ranOnMain = await Task { CurrentThread.isMain }.value

        #expect(ranOnMain)
    }

    @Test("a nonisolated synchronous function called from the main actor stays on it")
    @MainActor
    func nonisolatedSynchronousCallStaysOnTheMainActor() {
        // `CurrentThread.isMain` is itself the nonisolated synchronous
        // declaration under test: it belongs to no actor, and it still reports
        // this one. `nonisolated` describes what a declaration needs, not where
        // it runs — a synchronous call is a jump, not a scheduling decision.
        #expect(CurrentThread.isMain)
    }

    // MARK: What does

    @Test("OffMainActor.run leaves the main actor, and the caller resumes on it")
    @MainActor
    func offMainActorRunHopsBothWays() async {
        #expect(CurrentThread.isMain)

        let ranOffMain = await OffMainActor.run { !CurrentThread.isMain }

        #expect(ranOffMain)
        // The return trip is the half that gets forgotten. The caller is
        // `@MainActor`, so resuming means re-acquiring the main actor.
        #expect(CurrentThread.isMain)
    }

    @Test("work that suspends off the main actor resumes off it too")
    @MainActor
    func suspensionInsideTheHopDoesNotReturnToTheMainActor() async throws {
        let ranOffMain = try await OffMainActor.run {
            try await Task.sleep(for: .milliseconds(10))
            return !CurrentThread.isMain
        }

        #expect(ranOffMain)
    }

    @Test("MainActor.run carries a value onto the main actor from a nonisolated context")
    func mainActorRunReachesTheMainActor() async {
        // Deliberately not a `@MainActor` test: this is the trip in the other
        // direction, made from code that has no isolation of its own.
        let onMain = await OffMainActor.run {
            await MainActor.run { CurrentThread.isMain }
        }

        #expect(onMain)
    }

    // MARK: What the hop carries, and what Task.detached drops

    @Test("the hop keeps the caller's task-local values; Task.detached drops them")
    @MainActor
    func hopKeepsTaskLocalsWhereDetachedDropsThem() async {
        await TraceContext.$identifier.withValue("trace-42", operation: {
            // `run` never leaves the caller's task, so everything attached to
            // that task comes along: task locals, priority, cancellation.
            let viaHop = await OffMainActor.run { TraceContext.identifier }
            #expect(viaHop == "trace-42")

            // A detached task is a new, unstructured task with no parent. It
            // reaches the cooperative pool the same way and inherits none of it,
            // which is why it is the wrong default for "get off the main actor".
            let viaDetached = await Task.detached { TraceContext.identifier }.value
            #expect(viaDetached == "unset")
        })
    }

    @Test("cancelling the caller cancels the work running off the main actor")
    @MainActor
    func cancellingTheCallerCancelsTheHop() async {
        let work = Task { @MainActor in
            try await OffMainActor.run {
                try await Task.sleep(for: .seconds(1))
                return "finished"
            }
        }

        // Let the hop reach its suspension first, so this is cancellation of
        // work already running rather than of a task that never started. The
        // outcome is the same either way — `Task.sleep` throws immediately on an
        // already-cancelled task — so nothing here depends on the timing.
        try? await Task.sleep(for: .milliseconds(30))
        work.cancel()

        let outcome = await work.result
        #expect(throws: CancellationError.self) {
            try outcome.get()
        }
    }

    // MARK: assumeIsolated — reaching the main actor without a hop

    @Test("assumeIsolated reaches main-actor state from a synchronous Sendable callback")
    @MainActor
    func assumeIsolatedReachesMainActorStateSynchronously() {
        let counter = MainActorCounter()

        deliverSynchronously {
            // Inside a `@Sendable` closure there is no isolation, so
            // `counter.increment()` on its own does not compile. `MainActor.run`
            // is not the answer either: it is `async`, and a synchronous
            // callback has nowhere to put the `await` — and hopping would defer
            // the write past the callback's own return, which is precisely the
            // ordering the framework's contract rules out.
            //
            // `assumeIsolated` asserts what the framework already promises: this
            // callback arrives on the main thread. It traps if that is false,
            // which is the right failure — a wrong assumption about the calling
            // thread should be loud, not a silent data race.
            MainActor.assumeIsolated {
                counter.increment()
            }
        }

        // No suspension anywhere above, so the increment has already happened by
        // the time `deliverSynchronously` returns. That is the whole point of
        // reaching for it over a hop.
        #expect(counter.count == 1)
    }

    // MARK: The main actor is reentrant, like every other actor

    @Test("an await on the main actor releases it to other main-actor work")
    @MainActor
    func awaitReleasesTheMainActor() async {
        let counter = MainActorCounter()

        // Enqueued on the main actor, which this test is holding. It cannot run
        // until this function suspends.
        let other = Task { @MainActor in counter.increment() }

        // Still holding: there is no suspension point between the line above and
        // this read, so the enqueued work provably has not run.
        let beforeSuspension = counter.count

        // The `await` itself is the demonstration — no sleep, no timing
        // assumption. Reaching the line after it means this function suspended,
        // which means the main actor was released, which is the only way the
        // task above could have got to run.
        await other.value

        let afterSuspension = counter.count

        #expect(beforeSuspension == 0)
        // The `await` was not a lock. Main-actor state changed underneath a
        // method that was in the middle of running — the same reentrancy an
        // `actor` has, on the actor nobody thinks of as one.
        #expect(afterSuspension == 1)
    }
}
