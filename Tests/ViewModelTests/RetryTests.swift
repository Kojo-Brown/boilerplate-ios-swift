import Foundation
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

private enum SampleFailure: Error, Equatable {
    case transient
    case permanent
}

/// What is retried, what is not, and where the sleeps go.
///
/// The delays are recorded rather than spent — see `SleepLog` — so the schedule
/// is asserted exactly and the suite costs milliseconds. The two tests that do
/// spend real time are the two about cancellation, where the elapsed time *is*
/// the assertion.
@Suite("Retry", .serialized, .timeLimit(.minutes(1)))
struct RetryTests {

    /// No jitter and no cap in reach, so the delays are exactly the terms and
    /// the assertions can name them.
    private static let plainBackoff = Backoff(
        base: .milliseconds(100),
        multiplier: 2,
        cap: .seconds(30),
        jitter: .none
    )

    // MARK: The happy path

    @Test("a first-attempt success calls the operation once and never sleeps")
    func successOnTheFirstAttemptDoesNotSleep() async throws {
        let sleeps = SleepLog()
        let calls = LockedCounter()

        let value = try await Retry.run(sleep: sleeps.sleep) { _ in
            calls.increment()
            return 7
        }

        #expect(value == 7)
        #expect(calls.calls == 1)
        #expect(sleeps.delays.isEmpty)
    }

    @Test("a transient failure is retried on the schedule until it succeeds")
    func retriesOnTheScheduleUntilItSucceeds() async throws {
        let sleeps = SleepLog()
        let attempts = AttemptRecorder()
        let policy = Retry.Policy(
            maxAttempts: 4,
            backoff: Self.plainBackoff,
            isRetryable: { _ in true }
        )

        let value = try await Retry.run(policy, sleep: sleeps.sleep) { attempt in
            await attempts.record(attempt)
            guard attempt >= 3 else { throw SampleFailure.transient }
            return "ok"
        }

        #expect(value == "ok")
        // 1-based, and handed to the operation so it can carry an idempotency
        // key that is stable across the attempts of one logical request.
        #expect(await attempts.recorded == [1, 2, 3])
        #expect(sleeps.delays.map(milliseconds) == [100, 200])
    }

    // MARK: Where the loop stops

    @Test("the final attempt is not followed by a sleep")
    func exhaustionReportsTheLastFailureWithoutASleep() async {
        let sleeps = SleepLog()
        let calls = LockedCounter()
        let policy = Retry.Policy(
            maxAttempts: 3,
            backoff: Self.plainBackoff,
            isRetryable: { _ in true }
        )

        await #expect(throws: SampleFailure.transient) {
            try await Retry.run(policy, sleep: sleeps.sleep) { _ -> Int in
                calls.increment()
                throw SampleFailure.transient
            }
        }

        #expect(calls.calls == 3)
        // Two sleeps for three attempts. A loop that sleeps at the bottom
        // records three, and the third adds a whole backoff term of latency to
        // an outcome that was already decided.
        #expect(sleeps.delays.map(milliseconds) == [100, 200])
    }

    @Test("maxAttempts of 1 disables retrying")
    func aSingleAttemptPolicyNeverRetries() async {
        let sleeps = SleepLog()
        let calls = LockedCounter()
        let policy = Retry.Policy(maxAttempts: 1, isRetryable: { _ in true })

        await #expect(throws: SampleFailure.transient) {
            try await Retry.run(policy, sleep: sleeps.sleep) { _ -> Int in
                calls.increment()
                throw SampleFailure.transient
            }
        }

        #expect(calls.calls == 1)
        #expect(sleeps.delays.isEmpty)
    }

    @Test("a failure the policy does not classify as transient is not retried")
    func anUnclassifiedFailureIsNotRetried() async {
        let sleeps = SleepLog()
        let calls = LockedCounter()
        let policy = Retry.Policy(
            maxAttempts: 5,
            backoff: Self.plainBackoff,
            isRetryable: { ($0 as? SampleFailure) == .transient }
        )

        await #expect(throws: SampleFailure.permanent) {
            try await Retry.run(policy, sleep: sleeps.sleep) { _ -> Int in
                calls.increment()
                throw SampleFailure.permanent
            }
        }

        #expect(calls.calls == 1)
        #expect(sleeps.delays.isEmpty)
    }

    // MARK: Cancellation

    @Test("cancellation is not a transient failure, whatever the policy says")
    func cancellationIsNeverRetried() async {
        let sleeps = SleepLog()
        let calls = LockedCounter()
        // The strongest form of the assertion: a policy that retries absolutely
        // everything still must not retry a cancelled operation.
        let policy = Retry.Policy(
            maxAttempts: 5,
            backoff: Self.plainBackoff,
            isRetryable: { _ in true }
        )

        await #expect(throws: CancellationError.self) {
            try await Retry.run(policy, sleep: sleeps.sleep) { _ -> Int in
                calls.increment()
                throw CancellationError()
            }
        }

        #expect(calls.calls == 1)
        #expect(sleeps.delays.isEmpty)
    }

    @Test("cancelling during a backoff stops the loop rather than waiting it out")
    func cancellationDuringABackoffIsDeliveredAtOnce() async throws {
        let calls = LockedCounter()
        // A minute between attempts and the real `Task.sleep`, so a loop that
        // waited out its backoff before noticing cancellation would blow this
        // suite's time limit rather than pass it slowly.
        let policy = Retry.Policy(
            maxAttempts: 5,
            backoff: Backoff(base: .seconds(60), multiplier: 1, cap: .seconds(60), jitter: .none),
            isRetryable: { _ in true }
        )

        let task = Task {
            try await Retry.run(policy) { _ -> Int in
                calls.increment()
                throw SampleFailure.transient
            }
        }

        try await AsyncPoll.until("the first attempt never ran") {
            calls.calls == 1
        }
        task.cancel()

        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: CancellationError.self) {
            try await task.value
        }

        #expect(clock.now - start < .seconds(5))
        #expect(calls.calls == 1)
    }

    // MARK: Composition

    @Test("a per-attempt timeout composes with the retry policy")
    func aPerAttemptTimeoutComposes() async throws {
        let sleeps = SleepLog()
        let policy = Retry.Policy(
            maxAttempts: 3,
            backoff: Backoff(base: .milliseconds(10), multiplier: 2, cap: .seconds(1), jitter: .none),
            isRetryable: { $0 is TimedOutError }
        )

        let value = try await Retry.run(policy, sleep: sleeps.sleep) { attempt in
            try await withTimeout(.milliseconds(80)) {
                guard attempt >= 3 else {
                    try await Task.sleep(for: .seconds(30))
                    return 0
                }
                return attempt
            }
        }

        // Two attempts overran their own deadline and were retried; the third
        // answered. The deadline belongs to the attempt and the budget of
        // attempts belongs to the policy, and neither type knows the other
        // exists.
        #expect(value == 3)
        #expect(sleeps.delays.map(milliseconds) == [10, 20])
    }

    // MARK: The default classification

    @Test("the default classification retries only what a later attempt could answer")
    func theDefaultClassificationIsConservative() {
        #expect(Retry.isTransient(APIError.httpError(statusCode: 408, data: Data())))
        #expect(Retry.isTransient(APIError.httpError(statusCode: 429, data: Data())))
        #expect(Retry.isTransient(APIError.httpError(statusCode: 500, data: Data())))
        #expect(Retry.isTransient(APIError.httpError(statusCode: 503, data: Data())))

        #expect(!Retry.isTransient(APIError.httpError(statusCode: 400, data: Data())))
        #expect(!Retry.isTransient(APIError.httpError(statusCode: 404, data: Data())))
        // 501 and 505 are permanent statements about the endpoint, so "retry
        // 5xx" is one range too wide.
        #expect(!Retry.isTransient(APIError.httpError(statusCode: 501, data: Data())))
        #expect(!Retry.isTransient(APIError.httpError(statusCode: 505, data: Data())))

        #expect(!Retry.isTransient(APIError.unauthorized))
        #expect(!Retry.isTransient(APIError.tokenRefreshFailed))
        #expect(!Retry.isTransient(APIError.decodingFailed("unexpected key")))
        #expect(!Retry.isTransient(APIError.invalidURL))
        #expect(!Retry.isTransient(APIError.invalidResponse))
    }

    @Test("a cancelled URLSession call is not mistaken for a transient network failure")
    func aCancelledRequestIsNotTransient() {
        #expect(Retry.isTransient(URLError(.timedOut)))
        #expect(Retry.isTransient(URLError(.networkConnectionLost)))
        #expect(Retry.isTransient(URLError(.cannotConnectToHost)))
        #expect(Retry.isTransient(APIError.networkUnavailable(URLError(.dnsLookupFailed))))

        // The one that matters. Task cancellation reaches a caller of
        // `URLSession` as `URLError(.cancelled)` rather than as
        // `CancellationError`, so a loop that recognises only the latter retries
        // a screen the user has already dismissed.
        #expect(!Retry.isTransient(URLError(.cancelled)))
        #expect(!Retry.isTransient(APIError.networkUnavailable(URLError(.cancelled))))
        #expect(!Retry.isTransient(URLError(.badURL)))
        #expect(!Retry.isTransient(URLError(.userAuthenticationRequired)))
    }

    @Test("an error this package cannot classify is not retried")
    func anUnrecognisedErrorIsNotRetried() {
        // The safe direction for a default: not retrying costs one avoidable
        // failure, and retrying an unclassified write costs a duplicated side
        // effect nobody asked for.
        #expect(!Retry.isTransient(SampleFailure.transient))
        #expect(!Retry.isTransient(CancellationError()))
        #expect(!Retry.isTransient(TimedOutError(duration: .seconds(1))))
    }
}
