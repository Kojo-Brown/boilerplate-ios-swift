import Foundation
import os

/// Bridges a delegate- or callback-driven producer into an `AsyncStream`, with
/// the buffering policy — and therefore the loss it implies — chosen rather than
/// defaulted.
///
/// ```swift
/// private let frames = DelegateStream<CapturedFrame>(bufferingPolicy: .bufferingNewest(1))
///
/// func makeFrameStream() -> AsyncStream<CapturedFrame> {
///     frames.makeStream()
/// }
///
/// func captureOutput(
///     _: AVCaptureOutput,
///     didOutput sampleBuffer: CMSampleBuffer,
///     from _: AVCaptureConnection
/// ) {
///     frames.yield(CapturedFrame(buffer: sampleBuffer))
/// }
/// ```
///
/// ## A stream over a delegate has no backpressure to offer
///
/// Backpressure is a consumer telling a producer to slow down, and it needs a
/// producer that can be told. `AsyncStream` has the channel for it — `yield`
/// returns a `YieldResult` reporting the space left — and a delegate callback
/// has no way to act on it. `captureOutput` is a synchronous method AVFoundation
/// calls on a queue of its own; it cannot `await`, so it cannot be made to wait,
/// and a bridge that blocked inside it would block the capture queue instead,
/// which is worse than anything it was trying to prevent.
///
/// So the producer's rate is whatever the hardware does and the consumer's is
/// whatever the work takes. Where they differ, the difference has to go
/// somewhere, and there are only two somewheres: memory, or the floor. That is
/// the entire choice this type exists to make explicit, because `AsyncStream`
/// makes it silently — the default is `.unbounded`, which is memory, forever.
///
/// ## The safety valve the bridge disarms
///
/// `AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames` is already a drop
/// policy, and `CameraService` sets it. It drops a frame when the delegate is
/// *still executing* the previous one — which, once the delegate body is
/// `yield(…)` and nothing else, never happens. A yield returns in nanoseconds
/// whatever the consumer is doing, so AVFoundation sees a delegate that is never
/// late and hands over every frame at the full capture rate. Bridging to a
/// stream moves the queue from a place that had a bound to a place that does
/// not, and the bound is not replaced unless the policy replaces it.
///
/// What that costs is specific rather than theoretical. `AVCaptureVideoDataOutput`
/// vends sample buffers from a pool of fixed size, and a buffer returns to the
/// pool when the last reference to it goes away. An unbounded stream holds a
/// reference to every frame the consumer has not reached yet, so a consumer
/// slower than the capture rate drains the pool, and an output with no free
/// buffers stops delivering. Scanning stalls while the preview layer — fed by
/// its own connection to the session, not by this stream — keeps moving. That is
/// the confusing version of the bug, and the reason to pick the policy on
/// purpose.
///
/// ## Picking the policy
///
/// - `.bufferingNewest(1)` for a live signal where only the latest sample means
///   anything: video frames, location fixes, the position of a drag. The
///   consumer never works on stale input, the producer never waits, and the
///   backlog cannot exist.
/// - `.bufferingOldest(n)` where the first elements are the ones that matter and
///   a burst past `n` is a fault to report rather than absorb: a handshake
///   sequence, the opening errors of a storm.
/// - `.unbounded` only when something else already bounds the producer — a
///   finite document, a paged fetch, a callback the code itself drives. It is
///   not a default. It is a claim that no burst is possible.
///
/// Whatever the choice, `statistics` counts what it did, because a policy that
/// discards silently is indistinguishable from a producer that never fired.
///
/// ## One consumer at a time
///
/// An `AsyncStream` is not multicast: two tasks iterating the same stream split
/// the elements between them rather than each receiving all of them. So this
/// vends one live stream at a time, and a second `makeStream()` supersedes the
/// first, finishing it so that its consumer's `for await` *ends* instead of
/// waiting forever on a stream nothing will ever yield to again.
///
/// Superseding is why the continuation is tracked by generation. The termination
/// handler of a stream that has been replaced still runs, and the obvious body
/// for it — clear the stored continuation — would clear the *live* one and strand
/// its consumer. `CameraService.makeFrameStream()` had exactly that shape before
/// this type existed, and both view models call it on every `startScanning()`.
/// The generation is what lets a late handler recognise that it is reporting a
/// stream nobody is listening to any more, and do nothing.
package final class DelegateStream<Element: Sendable>: Sendable {
    package typealias BufferingPolicy = AsyncStream<Element>.Continuation.BufferingPolicy
    private typealias Continuation = AsyncStream<Element>.Continuation

    /// Why a stream ended, told to whoever was feeding it.
    package enum Termination: Sendable, Equatable {
        /// The producer called `finish()`.
        case finished
        /// The consuming task was cancelled, or dropped the stream unread.
        case cancelled
    }

    /// What became of one `yield`.
    package enum Delivery: Sendable, Equatable {
        /// Buffered, with nothing displaced to make room.
        case enqueued
        /// The buffering policy discarded an element: this one under
        /// `.bufferingOldest`, an older one under `.bufferingNewest`. Either way
        /// one element the producer emitted will not be seen.
        case dropped
        /// No stream was live, so there was nowhere to put it.
        case noConsumer
    }

    /// What the buffering policy has done so far. Readable from any thread.
    ///
    /// `dropped` counts *elements lost*, not yields refused — under
    /// `.bufferingNewest` the yield that reports a drop is the one whose element
    /// was kept, and the discarded one is the older sample it displaced. Lost is
    /// the number worth watching either way, since it is the one the consumer
    /// can tell you nothing about.
    package struct Statistics: Sendable, Equatable {
        /// Yields the buffer took with nothing displaced.
        package var enqueued = 0
        /// Elements the buffering policy discarded.
        package var dropped = 0
        /// Elements yielded while no stream was live.
        package var undelivered = 0

        /// Every yield, however it ended.
        package var total: Int { enqueued + dropped + undelivered }
    }

    /// Everything mutable, inside the lock rather than beside it, so this type
    /// is `Sendable` by the compiler's reckoning instead of by assertion — see
    /// `docs/concurrency.md`.
    private struct State: Sendable {
        var continuation: Continuation?
        var onTermination: (@Sendable (Termination) -> Void)?
        /// Bumped by every `makeStream()`. A termination handler naming an older
        /// generation is reporting a stream that has already been replaced, and
        /// must leave the live one alone.
        var generation = 0
        var statistics = Statistics()
    }

    private let bufferingPolicy: BufferingPolicy
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// - Parameter bufferingPolicy: What happens to elements the consumer has
    ///   not taken yet. There is no default: picking one is the point.
    package init(bufferingPolicy: BufferingPolicy) {
        self.bufferingPolicy = bufferingPolicy
    }

    // MARK: - Consuming

    /// Whether a stream is live to receive yields.
    package var hasConsumer: Bool {
        state.withLock { $0.continuation != nil }
    }

    /// A running count of what the buffering policy has done.
    package var statistics: Statistics {
        state.withLock { $0.statistics }
    }

    /// Starts the live stream, superseding and finishing any previous one.
    ///
    /// - Parameter onTermination: Called once when *this* stream ends, with the
    ///   reason. It is deliberately not called when a later `makeStream()`
    ///   supersedes it: being replaced is not the producer becoming unwanted, it
    ///   is somebody else wanting it, and a camera torn down there would race
    ///   the consumer that just asked for it.
    /// - Returns: A stream that yields until `finish()` or until its consumer
    ///   goes away.
    package func makeStream(
        onTermination: (@Sendable (Termination) -> Void)? = nil
    ) -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream(
            of: Element.self,
            bufferingPolicy: bufferingPolicy
        )

        let (generation, superseded) = state.withLock { current -> (Int, Continuation?) in
            current.generation += 1
            let previous = current.continuation
            current.continuation = continuation
            current.onTermination = onTermination
            return (current.generation, previous)
        }

        continuation.onTermination = { [weak self] reason in
            self?.streamEnded(generation: generation, reason: reason)
        }

        // Outside the lock. `finish()` runs the superseded stream's termination
        // handler, which comes straight back in here.
        superseded?.finish()

        return stream
    }

    /// Ends the live stream: its consumer drains whatever is buffered and its
    /// `for await` returns. Later yields report `.noConsumer` until the next
    /// `makeStream()`.
    package func finish() {
        let continuation = state.withLock { current -> Continuation? in
            let installed = current.continuation
            current.continuation = nil
            return installed
        }
        continuation?.finish()
    }

    // MARK: - Producing

    /// Offers one element to the live stream. Never waits, never blocks the
    /// caller, and is safe from whatever thread the delegate fires on.
    ///
    /// - Returns: What the buffering policy did with it.
    @discardableResult
    package func yield(_ element: Element) -> Delivery {
        // The continuation is read under the lock and used outside it, because
        // `yield` can resume a suspended consumer and nothing in this package
        // calls out from inside a lock. The cost of that is one benign race: a
        // `makeStream()` landing in between offers this element to the stream
        // that was live when the delegate fired, which reports `.terminated`
        // and is counted as undelivered. Which is the truth about the element.
        guard let continuation = state.withLock({ $0.continuation }) else {
            state.withLock { $0.statistics.undelivered += 1 }
            return .noConsumer
        }

        let delivery = Self.delivery(for: continuation.yield(element))

        state.withLock { current in
            switch delivery {
            case .enqueued: current.statistics.enqueued += 1
            case .dropped: current.statistics.dropped += 1
            case .noConsumer: current.statistics.undelivered += 1
            }
        }

        return delivery
    }

    // MARK: - Private

    /// Reads the stdlib's answer without switching over it exhaustively.
    ///
    /// `YieldResult` is a non-frozen enum from a resilient module, so an
    /// exhaustive `switch` over it is a compile-time bet either way — it wants
    /// `@unknown default` today and warns about a redundant one if the case set
    /// is ever frozen. Matching the two cases that carry meaning and reading
    /// everything else conservatively holds under both.
    private static func delivery(for result: Continuation.YieldResult) -> Delivery {
        if case .enqueued = result { return .enqueued }
        if case .dropped = result { return .dropped }
        // `.terminated`, plus anything a later SDK adds: nothing reached a
        // consumer, and an unrecognised answer is not evidence that it did.
        return .noConsumer
    }

    /// Runs when a stream ends, from whichever thread ended it.
    private func streamEnded(generation: Int, reason: Continuation.Termination) {
        let handler = state.withLock { current -> (@Sendable (Termination) -> Void)? in
            // An older generation is a stream `makeStream()` already replaced
            // and finished. Clearing here would detach the continuation that
            // took its place and leave its consumer on a stream nothing can
            // reach.
            guard current.generation == generation else { return nil }
            current.continuation = nil
            let installed = current.onTermination
            current.onTermination = nil
            return installed
        }

        // Matched rather than switched, for the reason `delivery(for:)` gives.
        if case .cancelled = reason {
            handler?(.cancelled)
        } else {
            handler?(.finished)
        }
    }
}
