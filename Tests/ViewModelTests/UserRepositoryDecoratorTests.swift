import Foundation
import SwiftData
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

// MARK: - Retry

@Suite("RetryingUserRepository — which failures are worth another attempt")
struct RetryingUserRepositoryTests {

    @Test("A transient read failure is retried and the second attempt answers")
    func transientFetchFailureIsRetried() async throws {
        let base = ScriptedRepository()
        base.fetchFailures = [serverAnswered]
        let log = SleepLog()
        let repository = RetryingUserRepository(base: base, sleep: log.sleep)

        let user = try await repository.fetchCurrentUser()

        #expect(user.email == "decorated@example.invalid")
        #expect(base.fetchCount == 2)
    }

    /// A 401 needs a token and a 400 needs a different request; neither comes
    /// out differently 200ms later, and retrying them turns one clear failure
    /// into a slow one.
    @Test("A permanent read failure is not retried")
    func permanentFetchFailureIsNotRetried() async {
        let base = ScriptedRepository()
        base.fetchFailures = [APIError.unauthorized, APIError.unauthorized, APIError.unauthorized]
        let log = SleepLog()
        let repository = RetryingUserRepository(base: base, sleep: log.sleep)

        await #expect(throws: APIError.self) {
            _ = try await repository.fetchCurrentUser()
        }

        #expect(base.fetchCount == 1)
        #expect(log.delays.isEmpty)
    }

    /// The pin on the sentence `docs/solid.md` finding 7 turns on: Phase 7
    /// shipped `Retry`, `Backoff` and `withTimeout` and the spec recorded that
    /// nothing called any of them. This fails if the retry loop stops being
    /// reached — and the recorded delays are the evidence that it is `Retry`
    /// doing the work rather than a hand-rolled loop, since they come from the
    /// injected `Retry.Sleep` seam.
    @Test("The retry combinators are on the path, and there is no sleep after the last attempt")
    func retryUsesTheCombinatorsThatHadNoCaller() async {
        let base = ScriptedRepository()
        base.fetchFailures = [serverAnswered, serverAnswered, serverAnswered]
        let log = SleepLog()
        let repository = RetryingUserRepository(base: base, sleep: log.sleep)

        await #expect(throws: APIError.self) {
            _ = try await repository.fetchCurrentUser()
        }

        #expect(base.fetchCount == 3)
        #expect(log.delays.count == 2)
        #expect(log.delays.allSatisfy({ $0 > .zero }))
    }

    /// The composition detail that is invisible until it bites: `isTransient`
    /// was written before anything called `withTimeout`, so a per-attempt
    /// deadline would otherwise make the first slow attempt terminal.
    @Test("A deadline is retryable here even though Retry does not recognise it")
    func deadlineOnAnAttemptIsRetryable() {
        let timedOut = TimedOutError(duration: .seconds(1))

        #expect(Retry.isTransient(timedOut) == false)
        #expect(RetryingUserRepository.isRetryableIdempotent(timedOut))
    }

    @Test("An attempt that overruns its deadline throws instead of waiting it out")
    func anAttemptThatOverrunsItsDeadlineThrowsTimedOut() async {
        let base = ScriptedRepository(beforeFetch: { _ = try? await Task.sleep(for: .seconds(10)) })
        let repository = RetryingUserRepository(
            base: base,
            idempotentPolicy: Retry.Policy(maxAttempts: 1),
            attemptTimeout: .milliseconds(50)
        )

        await #expect(throws: TimedOutError.self) {
            _ = try await repository.fetchCurrentUser()
        }
    }

    /// The decision finding 7 said had nowhere to live. The server answered, so
    /// it received the `PATCH`; whether it applied it before answering is not
    /// something a 503 says, and sending it again could apply it twice.
    @Test("A write is not retried when the server answered")
    func writeIsNotRetriedWhenTheServerAnswered() async {
        let base = ScriptedRepository()
        base.updateFailures = [serverAnswered, serverAnswered]
        let log = SleepLog()
        let repository = RetryingUserRepository(base: base, sleep: log.sleep)

        await #expect(throws: APIError.self) {
            _ = try await repository.updateProfile(name: "Retried")
        }

        #expect(base.updateCount == 1)
        #expect(log.delays.isEmpty)
    }

    @Test("A write is retried when the request never left the device")
    func writeIsRetriedWhenTheRequestNeverLeftTheDevice() async throws {
        let base = ScriptedRepository()
        base.updateFailures = [neverDelivered]
        let log = SleepLog()
        let repository = RetryingUserRepository(base: base, sleep: log.sleep)

        let user = try await repository.updateProfile(name: "Retried")

        #expect(user.name == "Retried")
        #expect(base.updateCount == 2)
        #expect(log.delays.count == 1)
    }

    /// The sharp edge of the same rule: a timeout means the connection existed,
    /// so the request may have been delivered and the answer lost.
    @Test("A write is not retried after a timeout, which proves nothing")
    func writeIsNotRetriedOnATimeout() async {
        let base = ScriptedRepository()
        base.updateFailures = [deliveryUnknown, deliveryUnknown]
        let repository = RetryingUserRepository(base: base, sleep: SleepLog().sleep)

        await #expect(throws: APIError.self) {
            _ = try await repository.updateProfile(name: "Retried")
        }

        #expect(base.updateCount == 1)
    }

    /// `DELETE` is idempotent by the method's own definition, so it takes the
    /// read policy rather than the write one.
    @Test("Deleting the account is retried like a read")
    func deleteIsTreatedAsIdempotent() async throws {
        let base = ScriptedRepository()
        base.deleteFailures = [serverAnswered]
        let repository = RetryingUserRepository(base: base, sleep: SleepLog().sleep)

        try await repository.deleteAccount()

        #expect(base.deleteCount == 2)
    }
}

// MARK: - Cache

@Suite("CachingUserRepository — a de-duplication window, not a policy")
struct CachingUserRepositoryTests {

    @Test("Repeated reads inside the window make one request")
    func repeatedReadsInsideTheWindowMakeOneRequest() async throws {
        let base = ScriptedRepository()
        let repository = CachingUserRepository(base: base)

        _ = try await repository.fetchCurrentUser()
        _ = try await repository.fetchCurrentUser()
        _ = try await repository.fetchCurrentUser()

        #expect(base.fetchCount == 1)
    }

    @Test("A read after the window goes back to the repository")
    func aReadAfterTheWindowGoesBackToTheRepository() async throws {
        let clock = ManualClock()
        let base = ScriptedRepository()
        let repository = CachingUserRepository(
            base: base,
            timeToLive: .seconds(5),
            now: clock.now
        )

        _ = try await repository.fetchCurrentUser()
        clock.advance(by: .seconds(4))
        _ = try await repository.fetchCurrentUser()
        #expect(base.fetchCount == 1)

        clock.advance(by: .seconds(2))
        _ = try await repository.fetchCurrentUser()
        #expect(base.fetchCount == 2)
    }

    /// `SingleFlightCache`'s subject, reached through the decorator: the
    /// readers arrive while the first load is still in flight, so there is no
    /// cached value for any of them to find and the naive cache would issue
    /// eight requests.
    @Test("Concurrent reads of a cold cache collapse into one request")
    func concurrentReadsCollapseIntoOneRequest() async throws {
        let base = ScriptedRepository(beforeFetch: { _ = try? await Task.sleep(for: .milliseconds(80)) })
        let repository = CachingUserRepository(base: base)

        try await withThrowingTaskGroup(of: User.self) { group in
            for _ in 0..<8 {
                group.addTask { try await repository.fetchCurrentUser() }
            }
            try await group.waitForAll()
        }

        #expect(base.fetchCount == 1)
    }

    /// The property that keeps an offline app from looking online: only
    /// successful loads are memoised, so a failure is a failure again next
    /// time.
    @Test("A failed read is never memoised")
    func failuresAreNeverMemoised() async throws {
        let base = ScriptedRepository()
        base.fetchFailures = [neverDelivered]
        let repository = CachingUserRepository(base: base)

        await #expect(throws: APIError.self) {
            _ = try await repository.fetchCurrentUser()
        }
        let user = try await repository.fetchCurrentUser()

        #expect(user.name == "Decorated User")
        #expect(base.fetchCount == 2)
    }

    @Test("Updating the profile drops the memo")
    func updatingTheProfileDropsTheMemo() async throws {
        let base = ScriptedRepository()
        let repository = CachingUserRepository(base: base)

        _ = try await repository.fetchCurrentUser()
        _ = try await repository.updateProfile(name: "Edited")
        let user = try await repository.fetchCurrentUser()

        #expect(user.name == "Edited")
        #expect(base.fetchCount == 2)
    }

    /// The path worth reading twice: a write that threw may still have been
    /// applied, so keeping the memo would leave it authoritative about a
    /// profile the server has already replaced.
    @Test("A failed update drops the memo as well")
    func aFailedUpdateAlsoDropsTheMemo() async throws {
        let base = ScriptedRepository()
        base.updateFailures = [deliveryUnknown]
        let repository = CachingUserRepository(base: base)

        _ = try await repository.fetchCurrentUser()
        await #expect(throws: APIError.self) {
            _ = try await repository.updateProfile(name: "Edited")
        }
        _ = try await repository.fetchCurrentUser()

        #expect(base.fetchCount == 2)
    }

    @Test("Deleting the account drops the memo")
    func deletingTheAccountDropsTheMemo() async throws {
        let base = ScriptedRepository()
        let repository = CachingUserRepository(base: base)

        _ = try await repository.fetchCurrentUser()
        try await repository.deleteAccount()
        _ = try await repository.fetchCurrentUser()

        #expect(base.fetchCount == 2)
    }

    /// The invariant `docs/decorators.md` calls load-bearing. If this memo ever
    /// outlived the sync layer's own window, `CacheFirstSyncStrategy` would
    /// decide its window had expired, go to the API for a fresh value, and be
    /// answered out of here — silently.
    @Test("The memo window is far inside the sync layer's freshness window")
    func cacheTimeToLiveIsWellInsideTheSyncWindow() {
        let memo = CachingUserRepository.defaultTimeToLive
        let policy = LiveSyncStrategyFactory.defaultCacheMaxAge

        #expect(memo < policy)
        #expect(memo * 10 <= policy)
    }
}

// MARK: - Telemetry

@Suite("TelemetryUserRepository — measuring without changing")
struct TelemetryUserRepositoryTests {

    @Test("Every operation is recorded under its own name")
    func aSuccessfulCallIsRecordedWithItsOperation() async throws {
        let telemetry = RecordingRepositoryTelemetry()
        let repository = TelemetryUserRepository(base: ScriptedRepository(), telemetry: telemetry)

        _ = try await repository.fetchCurrentUser()
        _ = try await repository.updateProfile(name: "Measured")
        try await repository.deleteAccount()

        #expect(telemetry.operations == [.fetchCurrentUser, .updateProfile, .deleteAccount])
        #expect(telemetry.outcomes == [.succeeded, .succeeded, .succeeded])
    }

    /// A caller that catches `APIError` must not start missing failures because
    /// something upstream decided to measure them.
    @Test("A failure is recorded and rethrown unchanged")
    func aFailureIsRecordedAndRethrownUnchanged() async {
        let base = ScriptedRepository()
        base.fetchFailures = [serverAnswered]
        let telemetry = RecordingRepositoryTelemetry()
        let repository = TelemetryUserRepository(base: base, telemetry: telemetry)

        await #expect(throws: APIError.self) {
            _ = try await repository.fetchCurrentUser()
        }

        #expect(telemetry.outcomes == [.failed("http(503)")])
    }

    /// Both spellings, because a `URLSession` task stopped by task cancellation
    /// reports `URLError(.cancelled)` rather than `CancellationError` — and a
    /// dashboard that counted dismissed screens as transport failures would
    /// panic every time a user swiped back.
    @Test("Cancellation is its own outcome, in either spelling")
    func cancellationIsNotRecordedAsAFailure() async {
        let base = ScriptedRepository()
        base.fetchFailures = [
            CancellationError(),
            APIError.networkUnavailable(URLError(.cancelled)),
        ]
        let telemetry = RecordingRepositoryTelemetry()
        let repository = TelemetryUserRepository(base: base, telemetry: telemetry)

        await #expect(throws: CancellationError.self) {
            _ = try await repository.fetchCurrentUser()
        }
        await #expect(throws: APIError.self) {
            _ = try await repository.fetchCurrentUser()
        }

        #expect(telemetry.outcomes == [.cancelled, .cancelled])
    }

    /// The rule `DiagnosticRecord` states, applied a layer up: a diagnostic
    /// string outlives the process and is routinely attached to a bug report,
    /// so treat everything in it as published. A `localizedDescription` here
    /// would carry the failing URL, its query string, and anything in it.
    @Test("Failure labels carry a category, never the error's message")
    func labelsCarryNoErrorMessage() {
        let decoding = APIError.decodingFailed(
            "keyNotFound(email) for https://api.example.invalid/users/me?token=not-a-real-token"
        )

        #expect(RepositoryOutcome.label(for: decoding) == "decodingFailed")
        #expect(RepositoryOutcome.label(for: serverAnswered) == "http(503)")
        #expect(RepositoryOutcome.label(for: neverDelivered) == "transport(-1009)")
        #expect(RepositoryOutcome.label(for: URLError(.timedOut)) == "transport(-1001)")
        #expect(RepositoryOutcome.label(for: UserRepositoryError.notFound) == "notFound")
        #expect(RepositoryOutcome.label(for: TimedOutError(duration: .seconds(1))) == "attemptTimedOut")
    }

    @Test("The recorded duration comes from the injected clock")
    func theRecordedDurationComesFromTheInjectedClock() async throws {
        let clock = ManualClock()
        let base = ScriptedRepository(beforeFetch: { clock.advance(by: .milliseconds(250)) })
        let telemetry = RecordingRepositoryTelemetry()
        let repository = TelemetryUserRepository(
            base: base,
            telemetry: telemetry,
            now: clock.now
        )

        _ = try await repository.fetchCurrentUser()

        let call = try #require(telemetry.calls.first)
        #expect(milliseconds(call.duration) == 250)
        #expect(call.summary == "fetchCurrentUser ok in 250ms")
    }
}

// MARK: - The composition

@Suite("The decorator chain as the container composes it")
struct UserRepositoryChainTests {

    /// The pin on the order, which is the design. Reordering these changes what
    /// the telemetry measures and what a cache hit costs, and without
    /// `UserRepositoryDecorator.base` to walk, none of that would be visible to
    /// a test.
    @Test("The container wraps telemetry over cache over retry over the live repository")
    @MainActor
    func decoratorChainIsTelemetryOverCacheOverRetry() throws {
        let modelContainer = try PersistenceController.makeInMemoryContainer()
        let container = AppContainer.live(
            userStore: SwiftDataUserPersistenceService(context: modelContainer.mainContext)
        )

        #expect(chainNames(of: container.userRepository) == [
            "TelemetryUserRepository",
            "CachingUserRepository",
            "RetryingUserRepository",
            "LiveUserRepository",
        ])
    }

    /// What the chosen order means, as an observation rather than a claim: with
    /// telemetry outermost, a cache hit is a recorded call that cost no
    /// request. Innermost it would be the other way round — one record per
    /// transport attempt and none for a hit — which is what an error-budget
    /// dashboard wants and not what "how long did the user wait" is.
    @Test("Telemetry outermost records the cache hit that made no request")
    func telemetryOutermostSeesTheCacheHit() async throws {
        let base = ScriptedRepository()
        let telemetry = RecordingRepositoryTelemetry()
        let repository = TelemetryUserRepository(
            base: CachingUserRepository(base: base),
            telemetry: telemetry
        )

        _ = try await repository.fetchCurrentUser()
        _ = try await repository.fetchCurrentUser()

        #expect(base.fetchCount == 1)
        #expect(telemetry.calls.count == 2)
    }
}
