import Foundation

/// A child task's result together with the slot it belongs in.
///
/// The offset travels *with* the value because the group hands results back in
/// completion order and has no memory of what was submitted. Carrying it is what
/// turns "whoever finished first" into "wherever it came from".
private struct Indexed<Value: Sendable>: Sendable {
    let offset: Int
    let value: Value
}

/// Runs an async transform over a collection with a fixed ceiling on how many
/// run at once, returns the results in the collection's order, and lets no work
/// outlive the call.
///
/// ```swift
/// // Four downloads in flight at a time, thumbnails in the order the URLs came.
/// let thumbnails = try await ConcurrentMap.over(urls, maxConcurrent: 4) { url in
///     try await ImageLoader.thumbnail(at: url)
/// }
/// ```
///
/// This is the everyday use of a task group, and the three things it gets right
/// are the three a hand-written group usually gets wrong.
///
/// ## 1. A group is not a queue: `addTask` starts the work
///
/// The obvious spelling starts everything at once:
///
/// ```swift
/// try await withThrowingTaskGroup(of: Thumbnail.self) { group in
///     for url in urls {
///         group.addTask { try await ImageLoader.thumbnail(at: url) }   // ← all of them, now
///     }
///     ...
/// }
/// ```
///
/// `addTask` does not enqueue work for the group to pace; it creates a child
/// task that is immediately runnable. A group of 500 URLs opens 500 sockets, and
/// the cooperative thread pool — which is sized to the core count and is not
/// meant to be blocked — is only a limit on how many can be *executing*, not on
/// how many can be suspended on a socket each holding a buffer. This reads as a
/// server that starts refusing connections, or a memory ceiling hit on an older
/// device, under a load the simulator never produced.
///
/// The fix is to make the group's own capacity the throttle: prime it with
/// `maxConcurrent` children, then add exactly one more each time `next()` hands
/// back a result. The window stays full and never grows, with no semaphore and
/// no queue of pending closures — the group's `next()` is the backpressure.
/// `ConcurrentMapTests` measures the peak against both spellings.
///
/// ## 2. `next()` yields in completion order, not submission order
///
/// A group is a stream of results ordered by *whoever finishes first*, so
/// collecting them with `results.append(value)` scrambles the input order in a
/// way that is invisible whenever the transform is uniformly fast. It shows up
/// in production, on the slow network, as a list whose rows are shuffled — and
/// it shows up under test only if the fixtures have deliberately uneven timing,
/// which fixtures rarely do.
///
/// Each child here carries the offset it came from and its result is written to
/// that slot, so ordering is a property of the code rather than of how the race
/// happened to run.
///
/// ## 3. Structured means the work cannot outlive the call
///
/// `withThrowingTaskGroup` does not return until every child has finished, on
/// all three exits:
///
/// - **Success** — the loop below drains `next()` until it returns `nil`.
/// - **A child throws** — `next()` rethrows, this closure exits, and the group
///   cancels the remaining children and awaits them before the error leaves
///   `over(_:maxConcurrent:transform:)`. The first error wins; siblings still
///   running are cancelled, not abandoned.
/// - **The caller is cancelled** — cancellation propagates into every child,
///   `addTaskUnlessCancelled` stops the window being refilled, and the group
///   drains what is left.
///
/// That guarantee is the whole difference from a `for` loop full of `Task { }`,
/// which returns immediately with the work still running, cancels nothing, and
/// reports no errors to anyone.
package enum ConcurrentMap {
    /// Applies `transform` to every element, at most `maxConcurrent` at a time.
    ///
    /// - Parameters:
    ///   - elements: The inputs. Order is preserved in the result regardless of
    ///     the order the transforms finish in.
    ///   - maxConcurrent: How many transforms may be in flight at once. Must be
    ///     at least 1.
    ///   - transform: The work to run per element. `@Sendable` because each call
    ///     runs in its own child task, so it must not capture anything belonging
    ///     to the caller's actor.
    /// - Returns: The transformed elements, in `elements`' order.
    /// - Throws: The first error any transform throws — at which point the
    ///   remaining children are cancelled and awaited before this returns. Or
    ///   `CancellationError` if the caller was cancelled before every element
    ///   had a result.
    package static func over<Element: Sendable, Transformed: Sendable>(
        _ elements: [Element],
        maxConcurrent: Int,
        transform: @escaping @Sendable (Element) async throws -> Transformed
    ) async throws -> [Transformed] {
        precondition(maxConcurrent >= 1, "maxConcurrent must be at least 1, got \(maxConcurrent)")
        guard !elements.isEmpty else { return [] }

        let slots = try await withThrowingTaskGroup(
            of: Indexed<Transformed>.self,
            returning: [Transformed?].self
        ) { group in
            var filled = [Transformed?](repeating: nil, count: elements.count)
            var next = 0
            var inFlight = 0

            while true {
                // Fill the window up to its ceiling. `addTaskUnlessCancelled`
                // rather than `addTask`: a child added to a cancelled group is
                // born cancelled, and a transform that never checks for
                // cancellation runs to completion regardless — so declining to
                // add it is the only way not to start it.
                while inFlight < maxConcurrent, next < elements.count {
                    let offset = next
                    let element = elements[offset]
                    guard group.addTaskUnlessCancelled(operation: {
                        let value = try await transform(element)
                        return Indexed(offset: offset, value: value)
                    }) else {
                        break
                    }
                    next += 1
                    inFlight += 1
                }

                // One out, one in. `next()` suspends until some child finishes,
                // so the loop is paced by completions rather than by a timer or
                // a semaphore, and the count in flight never exceeds the window.
                guard inFlight > 0, let finished = try await group.next() else {
                    break
                }
                inFlight -= 1
                filled[finished.offset] = finished.value
            }

            return filled
        }

        // A hole means the window stopped being refilled, and cancellation is
        // the only thing that stops it: a thrown error leaves through `next()`
        // above and never reaches here. Reporting a half-filled array as success
        // is the failure mode worth ruling out — the caller gets fewer results
        // than inputs, in a shape that still typechecks, and never learns why.
        //
        // Work that finished before the cancellation landed is still returned.
        // Cancelling is a request to stop, not an instruction to discard what is
        // already paid for, and a caller that wants the stricter reading can ask
        // `Task.isCancelled` itself.
        return try slots.map { value in
            guard let value else { throw CancellationError() }
            return value
        }
    }
}
