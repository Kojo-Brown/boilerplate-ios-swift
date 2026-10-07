import Foundation
import Testing
@testable import Core

// MARK: - On disk

@Suite("The file-backed spool is what makes a payload survive the process")
struct FileCrashReportSpoolTests {

    /// A fresh directory per test, removed afterwards. The spool's whole job is to
    /// leave files behind, so a suite that shared one would be a suite whose tests
    /// drain each other's queues.
    private func makeSpool(capacity: Int = 8) -> (spool: FileCrashReportSpool, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "crash-spool-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (FileCrashReportSpool(directory: root, capacity: capacity), root)
    }

    private func remove(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    /// The contract the feature rests on: when `store` returns, the report is on
    /// disk. Asserted by reading it back through a *second* spool object, so the
    /// test cannot pass on an in-memory cache the first one happened to keep.
    @Test("A stored report is readable by a spool that has never seen it")
    func storeIsDurableBeforeItReturns() throws {
        let (spool, root) = makeSpool()
        defer { remove(root) }
        let report = CrashReportFixture.crash()

        try spool.store(report)

        let reopened = FileCrashReportSpool(directory: root)
        #expect(try reopened.stored().reports == [report])
    }

    @Test("The directory is created on first write rather than at init")
    func directoryIsCreatedLazily() throws {
        let (spool, root) = makeSpool()
        defer { remove(root) }
        #expect(!FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))

        try spool.store(CrashReportFixture.crash())

        #expect(FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
    }

    @Test("Reading a spool that was never written is empty, not an error")
    func readingAnAbsentSpoolIsEmpty() throws {
        let (spool, root) = makeSpool()
        defer { remove(root) }
        #expect(try spool.stored() == .empty)
    }

    /// MetricKit does not promise to deliver a payload once, and has been observed
    /// to repeat one after a restore. The digest is the filename, so a repeat
    /// overwrites rather than queueing a second upload of the same crash.
    @Test("Storing the same defect twice leaves one report")
    func storeIsIdempotentOnDigest() throws {
        let (spool, root) = makeSpool()
        defer { remove(root) }
        let report = CrashReportFixture.crash()

        try spool.store(report)
        try spool.store(report)

        #expect(try spool.stored().reports.count == 1)
    }

    /// Ordering comes from the filename and not from the file system, because
    /// asking for a creation date is a required-reason API this target would then
    /// have to declare. See `FileCrashReportSpool`.
    @Test("Reports come back oldest payload window first")
    func readingIsOrderedByWindow() throws {
        let (spool, root) = makeSpool()
        defer { remove(root) }
        let series = CrashReportFixture.series(count: 4)

        for report in series.reversed() {
            try spool.store(report)
        }

        #expect(try spool.stored().reports.map(\.windowEnd) == series.map(\.windowEnd))
    }

    @Test("A discarded report is gone and discarding twice is not an error")
    func discardRemovesAndIsIdempotent() throws {
        let (spool, root) = makeSpool()
        defer { remove(root) }
        let report = CrashReportFixture.crash()
        try spool.store(report)

        try spool.discard(digest: report.digest)
        try spool.discard(digest: report.digest)

        #expect(try spool.stored().reports.isEmpty)
    }

    /// The oldest go, which is the opposite of what a log would do: a report names
    /// the build it came from, so the front of a full spool is where the reports
    /// about builds the person has already replaced accumulate.
    @Test("At capacity the oldest reports are evicted")
    func capacityEvictsTheOldest() throws {
        let (spool, root) = makeSpool(capacity: 3)
        defer { remove(root) }
        let series = CrashReportFixture.series(count: 5)

        for report in series {
            try spool.store(report)
        }

        let kept = try spool.stored().reports
        #expect(kept.count == 3)
        #expect(kept.map(\.digest) == series.suffix(3).map(\.digest))
    }

    /// Re-storing a report that is already there must not evict anything: the
    /// count on disk does not change, so neither should the queue.
    @Test("Replacing a spooled report does not evict a different one")
    func replacingDoesNotEvict() throws {
        let (spool, root) = makeSpool(capacity: 2)
        defer { remove(root) }
        let series = CrashReportFixture.series(count: 2)
        for report in series {
            try spool.store(report)
        }

        try spool.store(series[0])

        #expect(try spool.stored().reports.count == 2)
    }

    /// A file this build cannot decode it will never be able to decode, so
    /// leaving it would mean re-reading and re-failing on it at every launch for
    /// as long as the app is installed.
    @Test("An undecodable spooled file is counted and deleted")
    func unreadableFilesAreDiscarded() throws {
        let (spool, root) = makeSpool()
        defer { remove(root) }
        try spool.store(CrashReportFixture.crash())
        let name = "00000000000001-deadbeef.json"
        try Data("not json".utf8).write(to: root.appending(path: name))

        let first = try spool.stored()
        #expect(first.unreadable == 1)
        #expect(first.reports.count == 1)

        // And it is gone, so the next read is clean rather than reporting it again.
        #expect(try spool.stored().unreadable == 0)
    }

    @Test("The filename sorts numerically and carries the digest")
    func fileNameIsSortableAndIdentifying() {
        let report = CrashReportFixture.crash()
        let name = FileCrashReportSpool.fileName(for: report)
        #expect(name.hasSuffix("-\(report.digest).json"))
        #expect(name.count == 14 + 1 + 64 + 5)
    }

    /// A device whose clock is before 1970 would otherwise produce a name starting
    /// with `-`, which sorts after every positive value and puts the oldest report
    /// last.
    @Test("A pre-epoch window end does not produce an unsortable name")
    func preEpochWindowIsClamped() {
        let report = CrashReport(
            windowStart: Date(timeIntervalSince1970: -200),
            windowEnd: Date(timeIntervalSince1970: -100),
            build: CrashReportFixture.build,
            subject: .hang(seconds: 1),
            callStack: .empty
        )
        #expect(FileCrashReportSpool.fileName(for: report).hasPrefix("00000000000000-"))
    }
}

// MARK: - In memory

@Suite("The in-memory spool behaves like the real one")
struct InMemoryCrashReportSpoolTests {

    /// A double that accepted reports the real spool would evict is a double that
    /// makes the bound untested, which is why this suite mirrors the one above.
    @Test("It enforces the same capacity, evicting the oldest")
    func capacityMatchesTheFileSpool() throws {
        let spool = InMemoryCrashReportSpool(capacity: 3)
        let series = CrashReportFixture.series(count: 5)

        for report in series {
            try spool.store(report)
        }

        #expect(spool.reports.map(\.digest) == series.suffix(3).map(\.digest))
    }

    @Test("It replaces on an equal digest rather than appending")
    func storeIsIdempotentOnDigest() throws {
        let spool = InMemoryCrashReportSpool()
        let report = CrashReportFixture.crash()

        try spool.store(report)
        try spool.store(report)

        #expect(spool.reports.count == 1)
    }

    @Test("It orders by payload window regardless of insertion order")
    func orderingMatchesTheFileSpool() throws {
        let spool = InMemoryCrashReportSpool()
        let series = CrashReportFixture.series(count: 4)

        for report in series.reversed() {
            try spool.store(report)
        }

        #expect(spool.reports.map(\.windowEnd) == series.map(\.windowEnd))
    }

    @Test("It can be made to fail, so a failing spool is testable")
    func failuresAreInjectable() {
        let spool = InMemoryCrashReportSpool()
        spool.failStores(with: .couldNotCreateDirectory(path: "/nowhere"))

        #expect(throws: CrashReportSpoolError.couldNotCreateDirectory(path: "/nowhere")) {
            try spool.store(CrashReportFixture.crash())
        }
    }
}
