import Foundation
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Networking

// MARK: - Scheduling

@Suite("BackgroundRefreshCoordinator — what it asks for, and when")
struct BackgroundRefreshSchedulingTests {

    @Test("With nothing failing, the next launch is asked for at the nominal interval")
    func aHealthyScheduleUsesTheInterval() throws {
        let scheduler = MockBackgroundTaskScheduler()
        let coordinator = makeRefreshCoordinator(
            policy: makeRefreshPolicy(),
            scheduler: scheduler,
            ledger: InMemoryBackgroundRefreshLedger(),
            refresh: {}
        )

        try coordinator.scheduleNext()

        let request = try #require(scheduler.submitted.first)
        #expect(request.identifier == refreshTestIdentifier)
        #expect(request.kind == .appRefresh)
        #expect(request.earliestBeginDate == refreshClockOrigin.addingTimeInterval(60))
    }

    /// The persisted count is an exponent, and this is where it is spent: the
    /// coordinator walks the schedule once per recorded failure rather than
    /// asking it for its first term every launch.
    @Test(
        "Each recorded failure pushes the next launch one term further out",
        arguments: zip(
            [1, 2, 3, 4, 5, 9],
            [300.0, 600.0, 1200.0, 2400.0, 3600.0, 3600.0]
        )
    )
    func failuresGrowTheDelay(failures: Int, expected: TimeInterval) throws {
        let scheduler = MockBackgroundTaskScheduler()
        let coordinator = makeRefreshCoordinator(
            policy: makeRefreshPolicy(),
            scheduler: scheduler,
            ledger: InMemoryBackgroundRefreshLedger(consecutiveFailures: failures),
            refresh: {}
        )

        try coordinator.scheduleNext()

        let request = try #require(scheduler.submitted.first)
        #expect(request.earliestBeginDate == refreshClockOrigin.addingTimeInterval(expected))
    }

    /// `scheduleNext()` is the path with a caller who is awake, so a rejection
    /// reaches them rather than being logged into a background process nobody
    /// reads.
    @Test("An explicit schedule propagates the scheduler's rejection")
    func anExplicitScheduleThrows() {
        let scheduler = MockBackgroundTaskScheduler()
        scheduler.submitError = BackgroundRefreshFailure.answeredFromCache
        let coordinator = makeRefreshCoordinator(
            policy: makeRefreshPolicy(),
            scheduler: scheduler,
            ledger: InMemoryBackgroundRefreshLedger(),
            refresh: {}
        )

        #expect(throws: BackgroundRefreshFailure.self) {
            try coordinator.scheduleNext()
        }
    }

    @Test("Cancelling names the identifier the policy schedules")
    func cancellingNamesTheIdentifier() {
        let scheduler = MockBackgroundTaskScheduler()
        let coordinator = makeRefreshCoordinator(
            policy: makeRefreshPolicy(),
            scheduler: scheduler,
            ledger: InMemoryBackgroundRefreshLedger(),
            refresh: {}
        )

        coordinator.cancel()

        #expect(scheduler.cancelled == [refreshTestIdentifier])
    }
}

// MARK: - Running a launch

@Suite("BackgroundRefreshCoordinator — one system launch, end to end")
struct BackgroundRefreshHandleTests {

    @Test("A successful launch clears the count and asks again at the interval")
    func successResetsAndReschedules() async throws {
        let scheduler = MockBackgroundTaskScheduler()
        let ledger = InMemoryBackgroundRefreshLedger(consecutiveFailures: 3)
        let coordinator = makeRefreshCoordinator(
            policy: makeRefreshPolicy(),
            scheduler: scheduler,
            ledger: ledger,
            refresh: {}
        )

        let outcome = await coordinator.handle()

        #expect(outcome == .refreshed)
        #expect(ledger.consecutiveFailures == 0)
        #expect(scheduler.submitted.count == 2)
        let last = try #require(scheduler.submitted.last)
        #expect(last.earliestBeginDate == refreshClockOrigin.addingTimeInterval(60))
    }

    /// The defect this type exists for: a handler that reschedules only on the
    /// success path leaves nothing pending when it throws, and a background task
    /// with no pending request is never launched again.
    @Test("The next launch is pending before the work is even attempted")
    func theChainIsKeptAliveBeforeTheWorkRuns() async {
        let scheduler = MockBackgroundTaskScheduler()
        let refresh = ScriptedRefresh(failures: [URLError(.timedOut)], scheduler: scheduler)
        let coordinator = makeRefreshCoordinator(
            policy: makeRefreshPolicy(),
            scheduler: scheduler,
            ledger: InMemoryBackgroundRefreshLedger(),
            refresh: refresh.work
        )

        await coordinator.handle()

        // One request was already accepted when the first attempt started.
        #expect(refresh.observedSubmissions.first == 1)
    }

    @Test("A failed launch counts, and backs the next one off")
    func failureCountsAndBacksOff() async throws {
        let scheduler = MockBackgroundTaskScheduler()
        let ledger = InMemoryBackgroundRefreshLedger()
        let coordinator = makeRefreshCoordinator(
            policy: makeRefreshPolicy(),
            scheduler: scheduler,
            ledger: ledger,
            refresh: { throw URLError(.notConnectedToInternet) }
        )

        let outcome = await coordinator.handle()

        #expect(outcome == .failed)
        #expect(ledger.consecutiveFailures == 1)
        let last = try #require(scheduler.submitted.last)
        #expect(last.earliestBeginDate == refreshClockOrigin.addingTimeInterval(300))
    }

    /// Two launches in a row, which is what the persisted count buys: the
    /// second failure is scheduled a term further out than the first, in a
    /// process that has learned nothing except what the ledger told it.
    @Test("A second consecutive failure is pushed further out than the first")
    func consecutiveFailuresCompound() async throws {
        let scheduler = MockBackgroundTaskScheduler()
        let ledger = InMemoryBackgroundRefreshLedger()
        let coordinator = makeRefreshCoordinator(
            policy: makeRefreshPolicy(),
            scheduler: scheduler,
            ledger: ledger,
            refresh: { throw URLError(.notConnectedToInternet) }
        )

        await coordinator.handle()
        await coordinator.handle()

        #expect(ledger.consecutiveFailures == 2)
        let last = try #require(scheduler.submitted.last)
        #expect(last.earliestBeginDate == refreshClockOrigin.addingTimeInterval(600))
    }

    /// The in-flight half of the retry: a transport blip is answered inside the
    /// launch, and the ledger never hears about it.
    @Test("A transient failure is retried within the launch and does not count")
    func aTransientFailureIsRetriedInPlace() async {
        let scheduler = MockBackgroundTaskScheduler()
        let ledger = InMemoryBackgroundRefreshLedger()
        let sleep = RecordingSleep()
        let refresh = ScriptedRefresh(failures: [URLError(.timedOut)])
        let coordinator = makeRefreshCoordinator(
            policy: makeRefreshPolicy(),
            scheduler: scheduler,
            ledger: ledger,
            sleep: sleep.sleep,
            refresh: refresh.work
        )

        let outcome = await coordinator.handle()

        #expect(outcome == .refreshed)
        #expect(refresh.calls == 2)
        #expect(sleep.durations.count == 1)
        #expect(ledger.consecutiveFailures == 0)
    }

    /// `Retry.isTransient` answers `false` for anything it does not recognise,
    /// which is what keeps an unattended launch from repeating a request the
    /// server has already refused.
    @Test("A non-transient failure is not retried inside the launch")
    func aPermanentFailureIsNotRetried() async {
        let scheduler = MockBackgroundTaskScheduler()
        let sleep = RecordingSleep()
        let refresh = ScriptedRefresh(failures: [BackgroundRefreshFailure.answeredFromCache])
        let coordinator = makeRefreshCoordinator(
            policy: makeRefreshPolicy(),
            scheduler: scheduler,
            ledger: InMemoryBackgroundRefreshLedger(),
            sleep: sleep.sleep,
            refresh: refresh.work
        )

        let outcome = await coordinator.handle()

        #expect(outcome == .failed)
        #expect(refresh.calls == 1)
        #expect(sleep.durations.isEmpty)
    }

    /// Expiration is the system taking its time back, not the server failing.
    /// Counting it would back the schedule off for a reason the network never
    /// gave.
    @Test("An expired launch is not counted as a failure")
    func expirationIsNotAFailure() async {
        let scheduler = MockBackgroundTaskScheduler()
        let ledger = InMemoryBackgroundRefreshLedger()
        let coordinator = makeRefreshCoordinator(
            policy: makeRefreshPolicy(),
            scheduler: scheduler,
            ledger: ledger,
            refresh: { throw CancellationError() }
        )

        let outcome = await coordinator.handle()

        #expect(outcome == .expired)
        #expect(ledger.consecutiveFailures == 0)
        // Only the entry submission: the chain is intact and nothing was
        // learned that would change when the next launch should be.
        #expect(scheduler.submitted.count == 1)
    }

    /// The same path driven by real task cancellation rather than a thrown
    /// `CancellationError`, because that is how SwiftUI's `.backgroundTask`
    /// delivers an expiration.
    ///
    /// The work sleeps rather than failing, which is what makes this
    /// deterministic instead of a race: whether the cancellation lands before
    /// the task body starts, before `Retry.run`'s check, or inside the sleep,
    /// every ordering produces a `CancellationError` and none of them produces
    /// a network failure that could report `.failed` instead. The sixty seconds
    /// are never spent — `Task.sleep` returns the moment it is cancelled, which
    /// is the property this arrangement depends on.
    @Test("A cancelled surrounding task reports as expired")
    func aCancelledTaskReportsExpired() async {
        let scheduler = MockBackgroundTaskScheduler()
        let ledger = InMemoryBackgroundRefreshLedger()
        let coordinator = makeRefreshCoordinator(
            policy: makeRefreshPolicy(),
            scheduler: scheduler,
            ledger: ledger,
            refresh: { try await Task.sleep(for: .seconds(60)) }
        )

        let task = Task { await coordinator.handle() }
        task.cancel()
        let outcome = await task.value

        #expect(outcome == .expired)
        #expect(ledger.consecutiveFailures == 0)
        #expect(scheduler.submitted.count == 1)
    }

    /// A rejection inside the handler has nowhere to be thrown to, so it must
    /// not take the outcome down with it — the work did succeed, and the caller
    /// still has to report that.
    @Test("A scheduler that refuses mid-launch does not change what happened")
    func aRefusedRescheduleDoesNotChangeTheOutcome() async {
        let scheduler = MockBackgroundTaskScheduler()
        scheduler.submitError = URLError(.cannotConnectToHost)
        let ledger = InMemoryBackgroundRefreshLedger()
        let coordinator = makeRefreshCoordinator(
            policy: makeRefreshPolicy(),
            scheduler: scheduler,
            ledger: ledger,
            refresh: {}
        )

        let outcome = await coordinator.handle()

        #expect(outcome == .refreshed)
        #expect(ledger.consecutiveFailures == 0)
        #expect(scheduler.submitted.isEmpty)
    }

    @Test("A processing policy submits processing requests on every path")
    func theKindSurvivesEveryPath() async {
        let scheduler = MockBackgroundTaskScheduler()
        let coordinator = makeRefreshCoordinator(
            policy: makeRefreshPolicy(kind: .processing(.networkOnly)),
            scheduler: scheduler,
            ledger: InMemoryBackgroundRefreshLedger(),
            refresh: { throw URLError(.notConnectedToInternet) }
        )

        await coordinator.handle()

        let kinds = scheduler.submitted.map(\.kind)
        #expect(kinds == [.processing(.networkOnly), .processing(.networkOnly)])
    }
}

// MARK: - The composition root's side

@Suite("The background refresh the app actually runs")
@MainActor
struct BackgroundRefreshWiringTests {

    @Test("The container's coordinator schedules the identifier the app registers")
    func theRootAndTheSceneAgreeOnTheIdentifier() {
        #expect(AppContainer.preview.backgroundRefresh.identifier == AppContainer.backgroundRefreshIdentifier)
    }

    /// The reason `live()` inspects `SyncOrigin` instead of treating any
    /// returned `User` as a refresh: `RemoteFirstSyncStrategy` answers out of
    /// the store when the device is offline, and a launch that read its own
    /// disk has refreshed nothing.
    @Test("A launch answered from the local store is a failed refresh")
    func aCachedAnswerIsNotARefresh() async {
        let strategy = MockSyncStrategy()
        strategy.stubbedOrigin = .localCache

        let scheduler = MockBackgroundTaskScheduler()
        let ledger = InMemoryBackgroundRefreshLedger()
        let coordinator = makeRefreshCoordinator(
            policy: makeRefreshPolicy(),
            scheduler: scheduler,
            ledger: ledger,
            refresh: {
                let synced = try await strategy.loadCurrentUser()
                guard synced.origin == .remote else {
                    throw BackgroundRefreshFailure.answeredFromCache
                }
            }
        )

        let outcome = await coordinator.handle()

        #expect(outcome == .failed)
        #expect(ledger.consecutiveFailures == 1)
    }

    @Test("A launch that reached the API is a refresh")
    func aRemoteAnswerIsARefresh() async {
        let strategy = MockSyncStrategy()
        strategy.stubbedOrigin = .remote

        let ledger = InMemoryBackgroundRefreshLedger(consecutiveFailures: 2)
        let coordinator = makeRefreshCoordinator(
            policy: makeRefreshPolicy(),
            scheduler: MockBackgroundTaskScheduler(),
            ledger: ledger,
            refresh: {
                let synced = try await strategy.loadCurrentUser()
                guard synced.origin == .remote else {
                    throw BackgroundRefreshFailure.answeredFromCache
                }
            }
        )

        let outcome = await coordinator.handle()

        #expect(outcome == .refreshed)
        #expect(ledger.consecutiveFailures == 0)
    }
}
