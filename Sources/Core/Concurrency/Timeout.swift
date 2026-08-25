import Foundation

/// Thrown by `withTimeout(_:operation:)` when the deadline arrives before the
/// operation finishes.
package struct TimedOutError: Error, Equatable, CustomStringConvertible {
    /// The budget that was exceeded.
    package let duration: Duration

    package var description: String {
        "operation timed out after \(duration)"
    }
}

/// What the race produced, so the two children can share one result type.
private enum Raced<Value: Sendable>: Sendable {
    case operation(Value)
    case deadline
}

/// Runs `operation` with a deadline, throwing `TimedOutError` if it is not
/// finished in time.
///
/// ```swift
/// // Each attempt gets 5 seconds; the retry policy owns the total budget.
/// let user = try await Retry.run { _ in
///     try await withTimeout(.seconds(5)) { try await api.user(id: id) }
/// }
/// ```
///
/// ## A timeout does not stop work. It stops waiting — and only sometimes
///
/// This is the fact the type exists to make unmissable, because the name
/// promises otherwise. `withTimeout` races `operation` against a sleep in a task
/// group, and when the sleep wins it cancels the operation and throws. But
/// cancellation in Swift is cooperative, and a task group **waits for its
/// children before it returns**. So if `operation` never checks for
/// cancellation, `cancelAll()` sets a flag nobody reads, the group blocks on the
/// child anyway, and `withTimeout(.seconds(1))` returns after however long the
/// operation actually takes — with a `TimedOutError`, correctly reporting a
/// deadline that did nothing to enforce itself.
///
/// `TimeoutTests` compiles and runs that case rather than describing it: an
/// operation written to ignore cancellation is put under a 50ms timeout, and the
/// test waits for that operation to *observe* its own cancellation — which is
/// the deadline firing — and then asserts that the call has still not returned.
/// It is not a bug to be fixed here. It is what
/// bounding an uncancellable operation costs, and the fix is at the other end —
/// `CancellableContinuation` is how a callback-based API in this package is made
/// stoppable, and the six bridges it documents are exactly the ones a timeout
/// cannot otherwise interrupt.
///
/// The escape hatch, deliberately not taken: running `operation` in an
/// unstructured `Task` and abandoning it at the deadline *would* let this return
/// on time. It would also leave work running with nobody awaiting it, nobody
/// cancelling it, and nowhere for its error to go — the "`Task { }` in a `for`
/// loop" that `ConcurrentMap` exists to argue against. Returning on time is not
/// worth an unowned task; being honest about the wait is cheaper.
///
/// ## Why the winner is cancelled even when the operation wins
///
/// `group.cancelAll()` runs on both paths, not just the timeout path. Without it
/// the sleeping child is still pending when the closure returns, the group waits
/// for it, and every successful call costs the full timeout — a 10-second budget
/// would make a 5ms request take 10 seconds. The success path is the one where
/// forgetting to cancel is invisible in review and obvious in production.
///
/// - Parameters:
///   - duration: The budget, measured on `ContinuousClock` via `Task.sleep` —
///     so it keeps running while the device is suspended, which is what a
///     network deadline should do.
///   - operation: The work. `@Sendable` because it runs in a child task.
/// - Returns: The operation's result, if it finished in time.
/// - Throws: `TimedOutError` if the deadline came first; whatever `operation`
///   threw if it failed first; `CancellationError` if the surrounding task was
///   cancelled, which is distinct from timing out and stays distinct.
package func withTimeout<Value: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    precondition(duration > .zero, "timeout must be positive, got \(duration)")

    return try await withThrowingTaskGroup(
        of: Raced<Value>.self,
        returning: Value.self
    ) { group in
        // `addTask` rather than `addTaskUnlessCancelled`, which is the opposite
        // of the choice `ConcurrentMap` makes and for the opposite reason. There
        // the point is not to *start* work in a cancelled group; here declining
        // both children would leave `next()` with nothing to hand back. A child
        // added to a cancelled group is born cancelled, so `Task.sleep` throws
        // `CancellationError` immediately and an already-cancelled caller gets
        // that rather than a fabricated timeout.
        group.addTask {
            let value = try await operation()
            return .operation(value)
        }
        group.addTask {
            try await Task.sleep(for: duration)
            return .deadline
        }

        // `next()` rethrows, so an operation that fails leaves through here
        // carrying its own error — the group then cancels the sleeper and awaits
        // it on the way out, which is why there is no `cancelAll()` on this path
        // and no leak either.
        guard let first = try await group.next() else {
            preconditionFailure("withTimeout raced two children and got no result")
        }
        group.cancelAll()

        switch first {
        case let .operation(value):
            return value
        case .deadline:
            throw TimedOutError(duration: duration)
        }
    }
}
