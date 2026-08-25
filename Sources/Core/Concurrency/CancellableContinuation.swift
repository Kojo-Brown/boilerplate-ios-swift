import Foundation
import os

/// Bridges a completion-handler API into `async` *and* wires Swift's cooperative
/// cancellation through to it, so cancelling the caller actually stops the work.
///
/// ```swift
/// func data(for request: URLRequest) async throws -> Data {
///     try await CancellableContinuation.run { finish in
///         let task = URLSession.shared.dataTask(with: request) { data, _, error in
///             finish(Result { if let error { throw error } else { return data ?? Data() } })
///         }
///         task.resume()
///         return { task.cancel() }   // ← how this particular API is stopped
///     }
/// }
/// ```
///
/// ## What the plain continuation leaves out
///
/// This package has six `withCheckedThrowingContinuation` bridges already — in
/// `TextRecognitionService`, `CameraService`, `BarcodeScannerService`,
/// `GoogleSignInService` and `AppleSignInService` — and none of them can be
/// cancelled. That is not an oversight in any one of them; it is what a bare
/// continuation is:
///
/// ```swift
/// try await withCheckedThrowingContinuation { continuation in
///     legacyAPI.start { continuation.resume(with: $0) }
/// }
/// ```
///
/// Cancelling the surrounding task sets `Task.isCancelled` and does nothing
/// else. There is no suspension point inside `legacyAPI.start` for cancellation
/// to be *delivered* to, because the work is not Swift concurrency's — it is a
/// callback the caller is parked on. So the task stays suspended until the
/// callback arrives on its own schedule. A screen dismissed mid-scan keeps the
/// camera running; a search superseded three keystrokes ago keeps its socket
/// open. `withTaskCancellationHandler` is the only way to be told, and telling
/// the underlying API is the only way to stop.
///
/// ## Why this needs a lock rather than a flag
///
/// `withTaskCancellationHandler`'s `onCancel` closure is not scheduled. It runs
/// **synchronously, on whichever thread called `cancel()`**, concurrently with
/// the operation body, and it can run at any point relative to it — including
/// before the body has started at all, since a task cancelled before it reaches
/// the handler has the handler invoked immediately.
///
/// Three interleavings follow from that, and each is a crash or a hang if the
/// state is a plain `var`:
///
/// - **Cancel before the continuation exists.** `onCancel` has nothing to
///   resume, so the body must notice on arrival and resume itself. Miss it and
///   the task hangs forever, because nothing will ever call the handler again.
/// - **Cancel while `start` is still running.** The cancel handle does not exist
///   yet — `start` has not returned it — so `onCancel` cannot use it. Whoever
///   receives the handle must check, on receipt, whether it is already stale.
///   Miss it and the underlying work runs on, uncancelled, with nobody waiting
///   for it.
/// - **Cancel just as the callback fires.** Both paths reach for the same
///   continuation. Resuming a continuation twice is not a race that produces a
///   wrong answer; it traps. `CheckedContinuation` makes it a clear
///   `SWIFT_TASK_DEBUG_LOG`-style fatal error instead of the memory corruption
///   `UnsafeContinuation` would give, which is the entire reason to pay for the
///   checked one in a bridge like this.
///
/// So exactly one of the three paths must win, decided under a lock, and the
/// losers must do nothing. `Bridge` below is that decision and nothing else: it
/// hands the continuation out at most once, and whoever gets it resumes it.
///
/// Per `docs/concurrency.md`, the state lives *inside* `OSAllocatedUnfairLock`
/// rather than beside it, so `Bridge` holds only `let` properties of `Sendable`
/// type and needs no `@unchecked Sendable`. Neither critical section awaits or
/// calls out while holding the lock: each one decides, releases, and only then
/// resumes or cancels.
package enum CancellableContinuation {
    /// Stops the underlying work. Returned by `start`, called at most once, and
    /// only when cancellation arrives before the work has finished.
    package typealias Cancel = @Sendable () -> Void

    /// Runs a completion-handler API as a cancellable `async` call.
    ///
    /// - Parameter start: Begins the work. It is handed a `finish` callback to
    ///   report the outcome exactly once, and returns the closure that stops the
    ///   work. Return `{}` for an API with nothing to cancel — the call still
    ///   throws `CancellationError` promptly, it just cannot stop the work.
    /// - Returns: The value `finish` reported.
    /// - Throws: The error `finish` reported, or `CancellationError` if the
    ///   caller was cancelled first.
    ///
    /// On cancellation this resumes with `CancellationError` immediately rather
    /// than waiting for the underlying API to acknowledge, and drops whatever
    /// `finish` reports afterwards. That is deliberate: cancellation is
    /// cooperative, so an API that never calls back after being cancelled is
    /// ordinary rather than broken, and a bridge that waited for it would turn
    /// that into a permanently suspended task.
    package static func run<Value: Sendable>(
        starting start: @escaping @Sendable (
            _ finish: @escaping @Sendable (Result<Value, any Error>) -> Void
        ) -> Cancel
    ) async throws -> Value {
        let bridge = Bridge<Value>()

        return try await withTaskCancellationHandler {
            // The continuation's type is pinned by `bridge.install` below rather
            // than spelled out here: `Bridge<Value>.Continuation` *is*
            // `CheckedContinuation<Value, any Error>`, so passing it to `install`
            // is what fixes the generic parameter.
            try await withCheckedThrowingContinuation { continuation in
                guard bridge.install(continuation) else {
                    // Cancellation landed before the body ran, so `onCancel`
                    // found no continuation to resume. Resume it here and never
                    // call `start`: the work has not begun and need not.
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let cancel = start { result in bridge.settle(with: result) }

                // `start` has returned, which is the first moment the handle
                // exists. Cancellation may have arrived while it was running,
                // in which case the handle is already stale and this is the
                // only place left that can act on it.
                if bridge.record(cancel) == .cancelImmediately {
                    cancel()
                }
            }
        } onCancel: {
            bridge.cancel()
        }
    }
}

/// The one-winner decision behind `CancellableContinuation.run`.
///
/// Split out as its own type so each critical section is a named method with one
/// job, rather than three closures reaching into a shared `var` from three
/// different threads.
private final class Bridge<Value: Sendable>: Sendable {
    typealias Continuation = CheckedContinuation<Value, any Error>
    typealias Handle = CancellableContinuation.Cancel

    /// What `record(_:)` tells its caller to do with the handle it just took.
    enum Disposition: Equatable {
        /// Stored for `cancel()` to use, or discarded because the work is done.
        case keep
        /// Cancellation arrived before the handle existed; call it now.
        case cancelImmediately
    }

    private struct State: Sendable {
        var continuation: Continuation?
        var cancel: Handle?
        var isCancelled = false
        /// Set by whichever of the three paths won. Every later one is a no-op.
        var isSettled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Takes ownership of the continuation.
    ///
    /// - Returns: `false` if cancellation already landed, in which case the
    ///   caller owns the continuation and must resume it with a
    ///   `CancellationError`. Nothing is stored in that case, so no later path
    ///   can resume it a second time.
    func install(_ continuation: Continuation) -> Bool {
        state.withLock { current -> Bool in
            guard !current.isCancelled else { return false }
            current.continuation = continuation
            return true
        }
    }

    /// Records the handle that stops the underlying work.
    func record(_ cancel: @escaping Handle) -> Disposition {
        state.withLock { current -> Disposition in
            // Cancelled first: the handle is stale on arrival, and `cancel()`
            // has already given up looking for it.
            guard !current.isCancelled else { return .cancelImmediately }
            // Finished inside `start`, synchronously. There is nothing left to
            // stop, so the handle is dropped rather than kept for later.
            guard !current.isSettled else { return .keep }
            current.cancel = cancel
            return .keep
        }
    }

    /// Delivers the outcome the underlying API reported.
    ///
    /// Safe to call more than once, and safe to call after cancellation: only
    /// the first caller of any path finds a continuation to resume.
    func settle(with result: Result<Value, any Error>) {
        let continuation = state.withLock { current -> Continuation? in
            guard !current.isSettled else { return nil }
            current.isSettled = true
            let installed = current.continuation
            current.continuation = nil
            current.cancel = nil
            return installed
        }
        // Outside the lock: resuming runs the awaiting task's next step, which
        // is arbitrary code and must not happen under a non-recursive lock.
        continuation?.resume(with: result)
    }

    /// Handles cancellation of the awaiting task.
    ///
    /// Runs synchronously on the cancelling thread, so it does the least
    /// possible under the lock and nothing that could suspend.
    func cancel() {
        let (handle, continuation) = state.withLock { current -> (Handle?, Continuation?) in
            // Recorded even when there is nothing to do yet: it is what tells
            // `install` and `record`, whenever they get here, that they arrived
            // after the cancellation rather than before it.
            current.isCancelled = true
            guard !current.isSettled else { return (nil, nil) }
            current.isSettled = true
            let stopping = current.cancel
            let installed = current.continuation
            current.cancel = nil
            current.continuation = nil
            return (stopping, installed)
        }
        handle?()
        continuation?.resume(throwing: CancellationError())
    }
}
