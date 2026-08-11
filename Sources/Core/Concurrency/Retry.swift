import Foundation

/// Runs an operation again after a transient failure, waiting a jittered
/// exponential delay between attempts.
///
/// ```swift
/// let user = try await Retry.run { attempt in
///     try await api.send(GetUser(id: id), idempotencyKey: "\(requestID)-\(attempt)")
/// }
/// ```
///
/// ## Three things a hand-written retry loop gets wrong
///
/// The shape everyone writes first is four lines, and each of the three defects
/// below survives code review because none of them is visible in the happy path.
///
/// ```swift
/// for _ in 0..<3 {
///     do { return try await send() } catch { }          // ← 1
///     try await Task.sleep(for: .seconds(1))            // ← 2, 3
/// }
/// ```
///
/// **1. A bare `catch` retries cancellation.** `CancellationError` is an error
/// like any other, so a dismissed screen or a superseded search does not stop —
/// it starts over, sleeps, and starts over again, and the caller who cancelled
/// waits out the whole budget for a result nobody wants. It is the reason a
/// retry wrapper so often makes `LatestOnlyTask`-style superseding stop working.
/// `run` refuses to retry once the surrounding task is cancelled, and checks
/// `Task.isCancelled` as well as the error type, because a cancelled
/// `URLSession` call reports `URLError(.cancelled)` rather than
/// `CancellationError`.
///
/// **2. A bare `catch` also retries what cannot succeed.** A 401 needs a token,
/// a 404 needs a different URL and a `decodingFailed` needs a code change; none
/// of them is going to come out differently in 800ms. Retrying them turns one
/// clear failure into a slow one, and — on a non-idempotent write — turns one
/// payment into three. Classification is a policy decision, so it is a
/// parameter: `Policy.isRetryable`, defaulting to `Retry.isTransient`, which
/// answers `false` for anything it does not recognise.
///
/// **3. The last attempt sleeps for nothing.** A loop that sleeps at the bottom
/// waits out a full backoff term after the final failure and then reports it.
/// With a 30s cap that is 30 seconds of latency added to an outcome that was
/// already decided. `run` sleeps *between* attempts and never after the last
/// one, which `RetryTests` asserts by counting sleeps rather than by reading the
/// code.
///
/// ## Retry does not make an operation idempotent
///
/// A retried request that timed out may well have been received and applied —
/// the response was lost, not the write. Nothing here can know that, so
/// `operation` is handed the attempt number: use it to carry an idempotency key
/// (the same one on every attempt of one logical request), or restrict the
/// policy to reads. `Retry.isTransient` deliberately does not retry a 4xx, but
/// a 503 on a `POST` is still a duplicate risk this type cannot resolve for you.
///
/// ## The operation runs in the caller's task
///
/// Unlike `ConcurrentMap.over`, `run` creates no child task: it awaits
/// `operation` inline, in a loop. There is no fan-out, no group, and nothing to
/// outlive the call — the only thing between attempts is a sleep. `operation` is
/// `@Sendable` because it is handed to a `nonisolated` function and so crosses
/// out of whatever isolation the caller has, not because it is run concurrently
/// with anything.
enum Retry {
    /// How the loop waits between attempts.
    ///
    /// Injected so a test can assert the delays without spending them, and so
    /// the "no sleep after the last attempt" guarantee is observable rather than
    /// merely stated. `Retry.taskSleep` is the default and is what production
    /// uses.
    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// What to retry, how often, and how long to wait.
    struct Policy: Sendable {
        /// Total attempts including the first. `1` disables retrying.
        let maxAttempts: Int
        /// The delay schedule between attempts.
        let backoff: Backoff
        /// Whether a failure is worth another attempt.
        let isRetryable: @Sendable (any Error) -> Bool

        /// - Parameters:
        ///   - maxAttempts: Total attempts including the first. Must be at least
        ///     1. Counted as attempts rather than retries because "3 retries"
        ///     reads as either 3 or 4 calls depending on who wrote the loop.
        ///   - backoff: The delay schedule. Jittered by default.
        ///   - isRetryable: The classification. Defaults to `Retry.isTransient`.
        init(
            maxAttempts: Int = 3,
            backoff: Backoff = Backoff(),
            isRetryable: @escaping @Sendable (any Error) -> Bool = Retry.isTransient
        ) {
            precondition(maxAttempts >= 1, "maxAttempts must be at least 1, got \(maxAttempts)")
            self.maxAttempts = maxAttempts
            self.backoff = backoff
            self.isRetryable = isRetryable
        }
    }

    /// The production sleep.
    static let taskSleep: Sleep = { try await Task.sleep(for: $0) }

    /// The default classification: `true` only for failures that a later attempt
    /// could plausibly answer differently.
    ///
    /// Unrecognised errors are **not** retried. That direction of the default is
    /// the whole point — an error this package cannot classify may well be a
    /// write that already happened, and the cost of not retrying it is one
    /// avoidable failure, against a duplicated side effect for getting it wrong
    /// the other way.
    static let isTransient: @Sendable (any Error) -> Bool = { Retry.transient($0) }

    /// Runs `operation`, retrying transient failures on a jittered backoff.
    ///
    /// - Parameters:
    ///   - policy: How many attempts, how long between them, and what qualifies.
    ///   - randomness: The jitter source. Injected for tests; defaults to the
    ///     system generator.
    ///   - sleep: How to wait between attempts. Injected for tests; defaults to
    ///     `Task.sleep(for:)`, which is cancellable — so a cancellation arriving
    ///     during a backoff is delivered at once rather than after the delay.
    ///   - operation: The work, handed the 1-based attempt number.
    /// - Returns: The first successful result.
    /// - Throws: The failure of the final attempt, unchanged — not a wrapper
    ///   around it, so `catch let error as APIError` still works at the call
    ///   site and the attempt count is not smuggled into the error type. Or
    ///   `CancellationError` if the caller was cancelled between attempts.
    static func run<Value: Sendable>(
        _ policy: Policy = Policy(),
        randomness: @escaping Backoff.UnitRandom = Backoff.systemRandom,
        sleep: @escaping Sleep = Retry.taskSleep,
        operation: @Sendable (_ attempt: Int) async throws -> Value
    ) async throws -> Value {
        var schedule = policy.backoff.schedule(using: randomness)
        var attempt = 1

        while true {
            // Cancellation that lands between attempts has no failing operation
            // to be noticed by, so it is checked for here. Without this, a task
            // cancelled during the backoff of an injected sleep that ignores
            // cancellation would go on to make another call.
            try Task.checkCancellation()

            do {
                return try await operation(attempt)
            } catch {
                // Cancellation is not a failure to be retried. The error is
                // rethrown as it came rather than replaced with a
                // `CancellationError`: `URLError(.cancelled)` says which request
                // stopped, and the caller that cancelled already knows why.
                guard !(error is CancellationError), !Task.isCancelled else { throw error }
                guard attempt < policy.maxAttempts else { throw error }
                guard policy.isRetryable(error) else { throw error }

                // Between attempts, never after the last one — the guard above
                // has already left for the final failure.
                try await sleep(schedule.next())
                attempt += 1
            }
        }
    }

    /// The body of `isTransient`, split out so the stored closure stays one line
    /// and the classification reads as ordinary code.
    private static func transient(_ error: any Error) -> Bool {
        switch error {
        case let apiError as APIError:
            transientAPIFailure(apiError)
        case let urlError as URLError:
            transientURLFailure(urlError)
        default:
            false
        }
    }

    /// Status codes worth another attempt.
    ///
    /// 5xx is deliberately not taken wholesale: 501 (not implemented) and 505
    /// (version not supported) are permanent statements about the endpoint, and
    /// retrying them is the same mistake as retrying a 400. 408 and 429 are the
    /// two 4xx codes that explicitly invite a later attempt.
    ///
    /// A 429 carrying `Retry-After` should be honoured over this schedule, which
    /// needs the header to reach the error — `APIError.httpError` carries the
    /// body and the status, not the response. That is a gap, and it is a change
    /// to `APIError` rather than to this table.
    private static let retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    private static func transientAPIFailure(_ error: APIError) -> Bool {
        // Spelled out case by case rather than with a `default`, so a new
        // `APIError` has to be classified here before it compiles instead of
        // silently inheriting "never retry".
        switch error {
        case let .httpError(statusCode, _):
            retryableStatusCodes.contains(statusCode)
        case let .networkUnavailable(urlError):
            transientURLFailure(urlError)
        case .invalidURL, .invalidResponse, .decodingFailed:
            // Deterministic given the same request: a second identical call
            // produces the same malformed URL and the same undecodable body.
            false
        case .unauthorized, .tokenRefreshFailed:
            // Answered by refreshing a token or signing in again, not by
            // repeating the call that was refused.
            false
        }
    }

    private static func transientURLFailure(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .notConnectedToInternet:
            true
        default:
            // `.cancelled` lands here, which matters: a `URLSession` task
            // stopped by task cancellation reports it as a `URLError`, and
            // retrying that is defect 1 from this type's documentation wearing
            // a different error type.
            false
        }
    }
}
