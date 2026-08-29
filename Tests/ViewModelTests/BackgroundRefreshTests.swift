import BackgroundTasks
import Foundation
import Testing
@testable import Core

// MARK: - The request

@Suite("BackgroundRefreshRequest — what the system is actually asked for")
struct BackgroundRefreshRequestTests {

    @Test("An app-refresh request becomes a BGAppRefreshTaskRequest")
    func appRefreshMapsToTheRefreshSubclass() {
        let begins = refreshClockOrigin.addingTimeInterval(900)
        let request = BackgroundRefreshRequest(
            identifier: refreshTestIdentifier,
            kind: .appRefresh,
            earliestBeginDate: begins
        )

        let system = request.systemRequest()

        #expect(system is BGAppRefreshTaskRequest)
        #expect(system.identifier == refreshTestIdentifier)
        #expect(system.earliestBeginDate == begins)
    }

    /// The point of the enum: constraints exist on exactly one of the two
    /// subclasses, and this is the branch that carries them.
    @Test("A processing request carries both constraints onto the system object")
    func processingMapsConstraints() throws {
        let request = BackgroundRefreshRequest(
            identifier: refreshTestIdentifier,
            kind: .processing(
                BackgroundRefreshConstraints(
                    requiresNetworkConnectivity: true,
                    requiresExternalPower: true
                )
            ),
            earliestBeginDate: nil
        )

        let system = try #require(request.systemRequest() as? BGProcessingTaskRequest)

        #expect(system.identifier == refreshTestIdentifier)
        #expect(system.requiresNetworkConnectivity)
        #expect(system.requiresExternalPower)
        #expect(system.earliestBeginDate == nil)
    }

    @Test("networkOnly asks for a connection and not for a charger")
    func networkOnlyDoesNotWaitForPower() {
        let constraints = BackgroundRefreshConstraints.networkOnly
        #expect(constraints.requiresNetworkConnectivity)
        #expect(constraints.requiresExternalPower == false)
        #expect(BackgroundRefreshConstraints.unconstrained == BackgroundRefreshConstraints())
    }

    /// A `BGAppRefreshTaskRequest` has nowhere to put a constraint, so the only
    /// honest way to model one is a kind that cannot carry it — and this is
    /// what stops a later edit from adding `requiresNetworkConnectivity` to
    /// every request and quietly meaning it for a third of them.
    @Test("An app-refresh request has no constraints to drop")
    func appRefreshCannotCarryConstraints() {
        #expect(BackgroundRefreshKind.appRefresh != .processing(.networkOnly))
        #expect(BackgroundRefreshKind.processing(.networkOnly) != .processing(.unconstrained))
    }
}

// MARK: - The policy defaults

@Suite("BackgroundRefreshPolicy — the defaults, and the trap they avoid")
struct BackgroundRefreshPolicyTests {

    @Test("The default reschedule schedule is grown from the interval, not from 100ms")
    func theDefaultBackoffIsInBackgroundUnits() {
        let policy = BackgroundRefreshPolicy(identifier: refreshTestIdentifier)

        #expect(policy.interval == .seconds(900))
        #expect(policy.failureBackoff.base == .seconds(900))
        #expect(policy.failureBackoff.cap == .seconds(21_600))
        #expect(policy.failureBackoff.multiplier == 2)
    }

    /// `.equal` rather than `.full`, which is the departure from `Retry`'s
    /// default and the one worth pinning: a backoff whose floor stays at zero
    /// lets a device on its ninth failure ask to be woken immediately.
    @Test("The reschedule jitter keeps a floor that grows")
    func theRescheduleJitterHasAFloor() {
        let policy = BackgroundRefreshPolicy(identifier: refreshTestIdentifier)
        #expect(policy.failureBackoff.jitter == .equal)

        var schedule = policy.failureBackoff.schedule(using: { 0 })
        // The worst draw is still half the term, not none of it.
        #expect(schedule.next() == .seconds(450))
        #expect(schedule.next() == .seconds(900))
    }

    /// `Backoff` traps when `cap < base`, so a daily refresh must not crash on
    /// the line that builds its own default.
    @Test("An interval longer than the cap widens the cap instead of trapping")
    func aDailyIntervalDoesNotTrap() {
        let policy = BackgroundRefreshPolicy(identifier: refreshTestIdentifier, interval: .seconds(86_400))
        #expect(policy.failureBackoff.cap == .seconds(86_400))
    }

    @Test("The in-flight budget is small, because a launch is short")
    func theInFlightBudgetIsSmall() {
        let policy = BackgroundRefreshPolicy(identifier: refreshTestIdentifier)
        #expect(policy.inFlightRetry.maxAttempts == 2)
        #expect(policy.inFlightRetry.backoff.cap == .seconds(8))
    }
}

// MARK: - The ledger

@Suite("BackgroundRefreshLedger — a count that outlives the process")
struct BackgroundRefreshLedgerTests {

    @Test("The in-memory ledger counts up and clears")
    func theInMemoryLedgerCountsAndClears() {
        let ledger = InMemoryBackgroundRefreshLedger()
        #expect(ledger.consecutiveFailures == 0)

        ledger.recordFailure()
        ledger.recordFailure()
        #expect(ledger.consecutiveFailures == 2)

        ledger.recordSuccess()
        #expect(ledger.consecutiveFailures == 0)
    }

    /// The count is an exponent that `BackgroundRefreshCoordinator` walks a
    /// schedule with, so an unclamped one is an unbounded loop on a device that
    /// has been offline for a month.
    @Test("Both ledgers stop counting where counting stops changing anything")
    func bothLedgersClamp() {
        let ceiling = UserDefaultsBackgroundRefreshLedger.failureCeiling
        let memory = InMemoryBackgroundRefreshLedger(consecutiveFailures: ceiling)
        memory.recordFailure()
        #expect(memory.consecutiveFailures == ceiling)

        let suite = "background-refresh-tests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let disk = UserDefaultsBackgroundRefreshLedger(taskIdentifier: refreshTestIdentifier, suiteName: suite)
        for _ in 0..<(ceiling + 3) {
            disk.recordFailure()
        }
        #expect(disk.consecutiveFailures == ceiling)
    }

    /// The property the whole protocol exists for: a second reader, standing in
    /// for the next process, sees what the first one wrote.
    @Test("The persisted ledger survives being read by a different instance")
    func thePersistedLedgerOutlivesItsWriter() {
        let suite = "background-refresh-tests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let writer = UserDefaultsBackgroundRefreshLedger(taskIdentifier: refreshTestIdentifier, suiteName: suite)
        writer.recordFailure()
        writer.recordFailure()

        let nextLaunch = UserDefaultsBackgroundRefreshLedger(taskIdentifier: refreshTestIdentifier, suiteName: suite)
        #expect(nextLaunch.consecutiveFailures == 2)

        nextLaunch.recordSuccess()
        #expect(writer.consecutiveFailures == 0)
    }

    /// Two tasks in one app must not pace each other, so the key carries the
    /// identifier.
    @Test("Two task identifiers keep two counts")
    func twoTasksDoNotShareACount() {
        let suite = "background-refresh-tests-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let profile = UserDefaultsBackgroundRefreshLedger(taskIdentifier: "profile", suiteName: suite)
        let media = UserDefaultsBackgroundRefreshLedger(taskIdentifier: "media", suiteName: suite)

        profile.recordFailure()
        #expect(profile.consecutiveFailures == 1)
        #expect(media.consecutiveFailures == 0)
    }
}
