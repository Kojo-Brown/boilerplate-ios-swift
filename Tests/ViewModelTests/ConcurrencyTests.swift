import Foundation
import Testing
import os
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

@Suite("PollingStream")
struct PollingStreamTests {
    @Test("yields the first value immediately")
    func yieldsFirstValue() async throws {
        let stream = PollingStream.make(interval: .seconds(60)) { 42 }

        let result = Task<Int?, Never> {
            for await value in stream { return value }
            return nil
        }

        #expect(await result.value == 42)
    }

    @Test("delivers multiple values over time")
    func deliversMultipleValues() async throws {
        let stream = PollingStream.make(interval: .milliseconds(20)) {
            UUID()  // unique value each call
        }

        let collectTask = Task<[UUID], Never> {
            var values: [UUID] = []
            for await value in stream {
                values.append(value)
                if values.count == 3 { break }
            }
            return values
        }

        let results = await collectTask.value
        #expect(results.count == 3)
        // Each poll returns a distinct UUID
        #expect(Set(results).count == 3)
    }

    @Test("stream finishes after consumer task breaks")
    func finishesAfterConsumerBreaks() async throws {
        let stream = PollingStream.make(interval: .milliseconds(20)) { true }

        let didFinish = Task<Bool, Never> {
            for await _ in stream { break }
            return true
        }

        #expect(await didFinish.value == true)
    }

    @Test("transient fetch errors keep stream alive")
    func transientErrorsKeepStreamAlive() async throws {
        let calls = CallCounter()
        let stream = PollingStream.make(interval: .milliseconds(10)) { () async throws -> Int in
            let call = calls.next()
            if call == 1 { throw URLError(.notConnectedToInternet) }
            return call
        }

        // Second call should succeed after the error on call 1
        let result = Task<Int?, Never> {
            for await value in stream { return value }
            return nil
        }

        let value = await result.value
        #expect(value != nil)
        #expect(value == 2)
    }
}

/// The time limit is the backstop for the polling loop below: a stream that
/// never ticks would otherwise spend its whole budget of sleeps before failing,
/// and on a suite this is the bound that reports it as a time-out with a name
/// rather than as a job that ran long. It is the same bound `SessionObserverTests`
/// took for the same reason.
@Suite("Task Cancellation — HomeViewModel", .timeLimit(.minutes(1)))
@MainActor
struct HomeViewModelConcurrencyTests {
    /// The stream appends on the main actor, so a single fixed sleep measures
    /// how busy that actor is rather than whether the stream ticks: six 20 ms
    /// intervals fit inside 120 ms only if nothing else in the bundle is holding
    /// the actor, and something else in the bundle usually is. That is how this
    /// failed on CI run 34405002270, where a suite laying out several hundred
    /// rows in one synchronous pass ran alongside it. Polling asserts the same
    /// thing — the count grows — without also asserting a deadline that belongs
    /// to the runner, and it is the same fix `SessionObserverTests` and
    /// `repeatedReadsInsideTheWindowMakeOneRequest` already carry.
    ///
    /// The stream is stopped at the end. Left running, a 20 ms poller appending
    /// on the main actor outlives this test and becomes the noise that breaks
    /// somebody else's.
    @Test("startLiveUpdates appends items over time")
    func startLiveUpdatesAppendsItems() async throws {
        let viewModel = HomeViewModel()
        await viewModel.onAppear()
        let baseline = viewModel.items.count

        viewModel.startLiveUpdates(interval: .milliseconds(20))
        defer { viewModel.stopLiveUpdates() }

        for _ in 0..<200 {
            if viewModel.items.count > baseline { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(viewModel.items.count > baseline)
    }

    @Test("stopLiveUpdates halts item growth")
    func stopLiveUpdatesHaltsGrowth() async throws {
        let viewModel = HomeViewModel()
        await viewModel.onAppear()

        viewModel.startLiveUpdates(interval: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(100))

        viewModel.stopLiveUpdates()

        // Allow any in-flight yield to settle
        try await Task.sleep(for: .milliseconds(30))
        let countAfterStop = viewModel.items.count

        // Wait again — count must not grow further
        try await Task.sleep(for: .milliseconds(100))
        #expect(viewModel.items.count == countAfterStop)
    }

    @Test("onDisappear cancels live updates")
    func onDisappearCancelsLiveUpdates() async throws {
        let viewModel = HomeViewModel()
        await viewModel.onAppear()

        viewModel.startLiveUpdates(interval: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(60))
        viewModel.onDisappear()

        try await Task.sleep(for: .milliseconds(30))
        let countAfterDisappear = viewModel.items.count
        try await Task.sleep(for: .milliseconds(100))

        #expect(viewModel.items.count == countAfterDisappear)
    }

    @Test("startLiveUpdates cancels previous task before starting new one")
    func startLiveUpdatesCancelsPreviousTask() async throws {
        let viewModel = HomeViewModel()
        await viewModel.onAppear()

        viewModel.startLiveUpdates(interval: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(50))
        let countMidway = viewModel.items.count

        // Re-calling startLiveUpdates should cancel the old task and start fresh
        viewModel.startLiveUpdates(interval: .milliseconds(20))
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.items.count > countMidway)

        viewModel.stopLiveUpdates()
    }
}

// MARK: - CallCounter (test helper)

/// Counts invocations from `@Sendable` closures.
///
/// `PollingStream.make` takes a `@Sendable` fetch closure and runs it on the
/// cooperative pool, so a captured `var` cannot be mutated from it — "mutation of
/// captured var in concurrently-executing code". Holding the count inside the lock
/// rather than beside it means this is `Sendable` outright, with no `@unchecked`.
private struct CallCounter: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: 0)

    /// Increments the count and returns the new value.
    func next() -> Int {
        state.withLock { count -> Int in
            count += 1
            return count
        }
    }
}
