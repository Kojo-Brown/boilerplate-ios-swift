import Foundation
import Testing
@testable import BoilerplateiOSSwift

// MARK: - Fixtures

private enum FixtureError: Error, Equatable {
    case sinkRefused
}

/// Builds a journal and hands back the sink it writes to.
///
/// The factory is isolated to the domain because everything it constructs is:
/// `DiagnosticJournal.init`, `InMemoryDiagnosticSink.init` and
/// `DiagnosticBudget.init` are all `@DiagnosticsActor`, so they cannot be called
/// from a nonisolated test body as arguments to one another. One hop in, one
/// tuple out — and the tuple crosses because both of its members are
/// `Sendable`, which they are by virtue of being isolated to the global actor.
@DiagnosticsActor
private func makeJournal(
    capacity: Int = 1_024
) -> (journal: DiagnosticJournal, sink: InMemoryDiagnosticSink) {
    let sink = InMemoryDiagnosticSink()
    return (DiagnosticJournal(sink: sink, budget: DiagnosticBudget(capacity: capacity)), sink)
}

/// A sink that refuses to write until told otherwise, for the flush-failure path.
@DiagnosticsActor
private final class FailingDiagnosticSink: DiagnosticSink {
    private(set) var written: [DiagnosticRecord] = []
    private var isFailing = true

    func write(_ batch: [DiagnosticRecord]) throws {
        guard !isFailing else { throw FixtureError.sinkRefused }
        written.append(contentsOf: batch)
    }

    func stopFailing() {
        isFailing = false
    }
}

@DiagnosticsActor
private func makeFailingJournal() -> (journal: DiagnosticJournal, sink: FailingDiagnosticSink) {
    let sink = FailingDiagnosticSink()
    return (DiagnosticJournal(sink: sink, budget: DiagnosticBudget(capacity: 64)), sink)
}

/// A type that has nothing to do with journalling except that it lives in the
/// same domain — which is the entire claim a global actor makes.
///
/// Note what `noteRetry` does not contain: an `await`. `journal` is in this
/// isolation domain, so calling it is a call and not a hop, and the loop cannot
/// be interleaved with another caller's records. Written as two separate actors,
/// every line of this body would be a suspension point.
@DiagnosticsActor
private final class DomainNeighbour {
    private let journal: DiagnosticJournal

    init(journal: DiagnosticJournal) {
        self.journal = journal
    }

    func noteRetry(attempts: Int) {
        for attempt in 1...attempts {
            journal.record(.network, "retry \(attempt)")
        }
    }
}

// MARK: - Probes

/// Reports whether the diagnostics domain is running on the main thread.
///
/// `CurrentThread.isMain` is `nonisolated` and synchronous, so it answers for
/// wherever it is called from — which here is inside the domain.
@DiagnosticsActor
private func domainIsOnMainThread() -> Bool {
    CurrentThread.isMain
}

/// Asks the domain's own executor to confirm this is its queue.
///
/// `checkIsolated()` is a `dispatchPrecondition`, so a wrong answer traps the
/// process rather than failing an expectation. That is the deal SE-0424 offers
/// and it is the right one here: an executor that is not installed is not a
/// flaky test, it is every claim in `DiagnosticsActor`'s documentation being
/// false. The visible failure is the whole suite dying with
/// `BUG IN CLIENT OF LIBDISPATCH: Assertion failed`, naming this frame.
@DiagnosticsActor
private func assertDomainIsOnItsExecutor() {
    DiagnosticsActor.shared.executor.checkIsolated()
}

// MARK: - Tests

@Suite("Global actor over a custom serial executor")
struct DiagnosticsActorTests {

    @Test("The domain runs off the main thread")
    @MainActor
    func domainRunsOffTheMainThread() async {
        #expect(CurrentThread.isMain, "the test body itself is @MainActor")
        let insideDomain = await domainIsOnMainThread()
        #expect(insideDomain == false)
    }

    /// The one that fails if `unownedExecutor` is ever dropped from
    /// `DiagnosticsActor`. Without it the actor silently falls back to the
    /// cooperative pool: still correct, still serial, and no longer on a thread
    /// it is allowed to block.
    @Test("The domain's jobs run on the executor's own queue")
    func domainRunsOnItsOwnQueue() async {
        await assertDomainIsOnItsExecutor()
        #expect(DiagnosticsActor.shared.executor.label == "com.boilerplate.iosswift.diagnostics")
    }

    /// Sixty-four callers, sixty-four consecutive numbers.
    ///
    /// `record` reads `nextSequence`, adds one, and appends, with no suspension
    /// point between the three. That is only atomic because the whole method
    /// runs inside one isolation domain — the property this asserts is the
    /// actor's serialisation, observed through the thing that would visibly
    /// break without it.
    @Test("Sequence numbers are gap-free and collision-free under concurrent callers")
    func sequencesAreGapFreeUnderConcurrency() async {
        let fixture = await makeJournal()
        let journal = fixture.journal

        await withTaskGroup(of: Void.self) { group in
            for index in 1...64 {
                group.addTask {
                    _ = await journal.record(.lifecycle, "event \(index)")
                }
            }
        }

        let sequences = await journal.pending.map(\.sequence).sorted()
        #expect(sequences == Array(UInt64(1)...UInt64(64)))
    }

    @Test("A second type in the domain reaches the journal without an await")
    func neighbourReachesJournalSynchronously() async {
        let fixture = await makeJournal()
        let neighbour = await DomainNeighbour(journal: fixture.journal)

        await neighbour.noteRetry(attempts: 3)

        let messages = await fixture.journal.pending.map(\.message)
        #expect(messages == ["retry 1", "retry 2", "retry 3"])
    }

    @Test("The budget refuses records past capacity and counts every refusal")
    func budgetRefusesPastCapacity() async {
        let fixture = await makeJournal(capacity: 4)
        var accepted = 0

        for index in 1...7 {
            if await fixture.journal.record(.network, "event \(index)") != nil {
                accepted += 1
            }
        }

        #expect(accepted == 4)
        let pending = await fixture.journal.pending
        #expect(pending.count == 4)
        let dropped = await fixture.journal.dropped
        #expect(dropped == 3)
    }

    @Test("Flushing hands the batch to the sink in order and empties the buffer")
    func flushDrainsInOrder() async throws {
        let fixture = await makeJournal()
        for index in 1...3 {
            _ = await fixture.journal.record(.persistence, "row \(index)")
        }

        try await fixture.journal.flush()

        let written = await fixture.sink.written
        #expect(written.map(\.message) == ["row 1", "row 2", "row 3"])
        #expect(written.map(\.sequence) == [1, 2, 3])
        let pending = await fixture.journal.pending
        #expect(pending.isEmpty)
    }

    /// A sink that throws must not cost the records it was handed. The buffer is
    /// cleared before the write, so the restore path is the only thing standing
    /// between a transient `ENOSPC` and a silently truncated log.
    @Test("A sink that throws leaves the batch buffered, in order, for the next flush")
    func failedFlushRestoresTheBatch() async throws {
        let fixture = await makeFailingJournal()
        for index in 1...3 {
            _ = await fixture.journal.record(.auth, "step \(index)")
        }

        await #expect(throws: FixtureError.sinkRefused) {
            try await fixture.journal.flush()
        }

        let afterFailure = await fixture.journal.pending.map(\.sequence)
        #expect(afterFailure == [1, 2, 3])

        await fixture.sink.stopFailing()
        try await fixture.journal.flush()

        let written = await fixture.sink.written
        #expect(written.map(\.sequence) == [1, 2, 3])
        let pending = await fixture.journal.pending
        #expect(pending.isEmpty)
    }

    @Test("A record renders as exactly one line however the message was written")
    func recordEscapesEmbeddedControlCharacters() {
        let record = DiagnosticRecord(
            sequence: 7,
            timestamp: Date(timeIntervalSince1970: 0),
            category: .network,
            message: "first\nsecond\tthird\\fourth"
        )

        #expect(record.line.contains("\n") == false)
        #expect(record.line.hasPrefix("7\t"))
        #expect(record.line.hasSuffix("\tfirst\\nsecond\\tthird\\\\fourth"))
    }

    @Test("The file sink appends one line per record and reopens where it left off")
    func fileSinkAppendsOneLinePerRecord() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("journal.log", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let sink = await FileDiagnosticSink(url: url)
        try await sink.write((1...3).map { index in
            DiagnosticRecord(
                sequence: UInt64(index),
                timestamp: stamp,
                category: .lifecycle,
                message: "line \(index)"
            )
        })

        // Closing and writing again is the reopen path: the sink has to create
        // nothing, seek to the end, and append rather than truncate.
        try await sink.close()
        let reopened = DiagnosticRecord(
            sequence: 4,
            timestamp: stamp,
            category: .network,
            message: "after reopen"
        )
        try await sink.write([reopened])
        try await sink.close()

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 4)
        #expect(lines.first?.hasPrefix("1\t") == true)
        #expect(lines.last?.hasSuffix("\tafter reopen") == true)
    }
}
