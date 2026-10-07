import Foundation
import os

// MARK: - Errors

/// What can go wrong between a report and the disk.
package enum CrashReportSpoolError: Error, Equatable {
    /// The spool directory did not exist and could not be created.
    case couldNotCreateDirectory(path: String)
    /// A spooled file is not a report this build can read.
    case unreadableRecord(name: String)
}

// MARK: - The seam

/// Somewhere a report waits between being handed over by MetricKit and being
/// accepted by a server.
///
/// ## Why every requirement here is synchronous
///
/// This is the one design decision the whole feature rests on, so it is stated
/// in the protocol rather than left in an implementation.
///
/// `MXMetricManagerSubscriber.didReceive(_:)` is called **once** per payload.
/// There is no acknowledgement, no re-delivery, and no way to ask for a payload
/// again: MetricKit hands over the previous day's diagnostics, typically within
/// seconds of a launch, and then forgets them. Whatever has not been made durable
/// by the time that callback returns is a crash report that no longer exists
/// anywhere.
///
/// An `async` requirement would make the obvious implementation of that callback
/// `Task { await spool.store(report) }`, which returns before the write happens
/// and hands the ordering to the scheduler. The window is small and it is
/// precisely the wrong window: MetricKit delivers at launch, launch is when an
/// app is most likely to be killed for taking too long, and a payload delivered
/// to a process that is terminated three hundred milliseconds later is a crash
/// nobody will ever see — the one that is hardest to reproduce and most worth
/// having.
///
/// So the contract is: when ``store(_:)`` returns, the report is on disk. The
/// cost is a blocking write inside a system callback, which is accepted
/// deliberately — it is a handful of kilobytes, and a dropped crash report is not
/// recoverable while a few milliseconds on a background callback is not a defect.
/// ``CrashReportPipeline`` is where the *upload* becomes asynchronous, which is
/// the part that is allowed to be.
package protocol CrashReportSpooling: Sendable {

    /// Makes `report` durable, returning only once it is.
    ///
    /// Storing a report whose digest is already spooled replaces it rather than
    /// adding a second copy — the digest identifies the defect, so two deliveries
    /// of one crash are one thing to upload.
    func store(_ report: CrashReport) throws

    /// Every spooled report, oldest payload window first.
    ///
    /// Reports that cannot be decoded are *discarded* rather than thrown, and the
    /// count of them is returned alongside. A single file written by a future
    /// build of the app must not be able to wedge the queue behind it.
    func stored() throws -> SpooledReports

    /// Forgets the report with this digest. Succeeds if it was never there.
    func discard(digest: String) throws
}

/// What a spool had, and what it threw away reading it.
package struct SpooledReports: Sendable, Equatable {

    /// The readable reports, oldest payload window first.
    package let reports: [CrashReport]

    /// How many spooled files could not be decoded and were deleted.
    ///
    /// Surfaced rather than swallowed, because the only way this is ever anything
    /// but zero is a format change — and a format change that quietly eats the
    /// previous version's queue should be visible in a log.
    package let unreadable: Int

    package init(reports: [CrashReport], unreadable: Int = 0) {
        self.reports = reports
        self.unreadable = unreadable
    }

    package static let empty = SpooledReports(reports: [], unreadable: 0)
}

// MARK: - On disk

/// A spool backed by one JSON file per report in a directory of its own.
///
/// ## Why a file per report and not one file
///
/// Because the two operations have to be safe against the process dying between
/// any two instructions, and they are at opposite ends of the queue: MetricKit
/// appends at launch, the uploader removes after each success. With one file
/// those are both read-modify-write over the whole queue, so an interrupted
/// upload loop can lose the reports it had already read; with a file each they
/// are an atomic create and an unlink, and the queue has no state of its own to
/// corrupt.
///
/// ## Why the filename carries the ordering
///
/// `<windowEnd as seconds, zero-padded>-<digest>.json`, sorted lexicographically.
/// The alternative is to ask the file system for creation dates, and that is a
/// required-reason API — `NSPrivacyAccessedAPICategoryFileTimestamp`, reason
/// `C617.1` — which would put a declaration in `Core`'s privacy manifest to buy
/// an ordering the reports already carry. Padding is what makes the lexicographic
/// sort a numeric one, and it is wide enough to stay monotonic past the year
/// 33,658.
///
/// Reports from one payload share a `windowEnd` and so sort by digest among
/// themselves, which is arbitrary. That is honest rather than unfortunate:
/// `MXDiagnosticPayload` timestamps the payload and not the diagnostics in it, so
/// there is no real order between two crashes from the same day to preserve.
package final class FileCrashReportSpool: CrashReportSpooling {

    /// The directory holding the queue. Created on first write.
    package let directory: URL

    /// How many reports may wait here. See ``CrashReportLimits/spoolCapacity``.
    package let capacity: Int

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Serialises the read-evict-write sequence in ``store(_:)``.
    ///
    /// A lock and not an actor, because the whole point of this type is that
    /// `store` is synchronous — see ``CrashReportSpooling``. Two writers are not
    /// hypothetical: the subscriber stores from MetricKit's callback while the
    /// pipeline is reading the directory to drain it.
    private let gate = OSAllocatedUnfairLock(initialState: ())

    /// - Parameters:
    ///   - directory: Where to keep the queue. A subdirectory of Application
    ///     Support rather than Caches, because the system is free to evict Caches
    ///     under pressure and the pressure that evicts it is correlated with the
    ///     crashes being reported.
    ///   - capacity: How many reports may wait. Reached, the oldest are dropped.
    package init(directory: URL, capacity: Int = CrashReportLimits.standard.spoolCapacity) {
        precondition(capacity > 0, "A spool with no capacity would discard every crash.")
        self.directory = directory
        self.capacity = capacity

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Sorted keys so that storing the same report twice produces the same
        // bytes. Nothing depends on it today; a build that starts checksumming
        // spool files would, and the cost is nil.
        encoder.outputFormatting = .sortedKeys
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// The default location: `Application Support/CrashReports`.
    package static func defaultDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appending(path: "CrashReports", directoryHint: .isDirectory)
    }

    package func store(_ report: CrashReport) throws {
        let data = try encoder.encode(report)
        let name = FileCrashReportSpool.fileName(for: report)
        try gate.withLock {
            try createDirectoryIfNeeded()
            // Evicted *before* the write, so capacity is a bound on what is on
            // disk rather than on what was on disk a moment ago. `capacity - 1`
            // because this report is about to join them — unless it is replacing
            // a file that is already there, which `names` sees and so does not
            // over-evict.
            let names = try spooledNames()
            if !names.contains(name) {
                try evict(from: names, downTo: capacity - 1)
            }
            try data.write(to: directory.appending(path: name), options: .atomic)
        }
    }

    package func stored() throws -> SpooledReports {
        try gate.withLock { () -> SpooledReports in
            guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
                return .empty
            }
            var reports: [CrashReport] = []
            var unreadable = 0
            for name in try spooledNames() {
                let url = directory.appending(path: name)
                do {
                    let data = try Data(contentsOf: url)
                    reports.append(try decoder.decode(CrashReport.self, from: data))
                } catch {
                    // Deleted rather than kept and skipped. A file this build
                    // cannot read it will never be able to read, and leaving it
                    // means re-reading and re-failing on it at every launch for
                    // as long as the app is installed.
                    unreadable += 1
                    try? FileManager.default.removeItem(at: url)
                }
            }
            return SpooledReports(reports: reports, unreadable: unreadable)
        }
    }

    package func discard(digest: String) throws {
        try gate.withLock {
            let suffix = "-\(digest).json"
            for name in try spooledNames() where name.hasSuffix(suffix) {
                try FileManager.default.removeItem(at: directory.appending(path: name))
            }
        }
    }

    // MARK: - Naming

    /// `<zero-padded seconds>-<digest>.json`.
    ///
    /// Negative window ends — a device whose clock is before 1970 — are clamped
    /// to zero rather than formatted with a minus sign, which would sort after
    /// every positive value and put the oldest report last.
    package static func fileName(for report: CrashReport) -> String {
        let seconds = max(0, Int(report.windowEnd.timeIntervalSince1970))
        return "\(String(format: "%014d", seconds))-\(report.digest).json"
    }

    // MARK: - Private

    private func spooledNames() throws -> [String] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return []
        }
        // `includingPropertiesForKeys: []` on purpose: asking for a resource key
        // here is how a file-timestamp declaration gets into `Core`'s privacy
        // manifest. The names carry everything this needs.
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [],
            options: [.skipsHiddenFiles]
        )
        return contents.map(\.lastPathComponent).filter { $0.hasSuffix(".json") }.sorted()
    }

    private func evict(from names: [String], downTo limit: Int) throws {
        guard names.count > limit else { return }
        // The *oldest* go, which is the opposite of what a log would do and is
        // deliberate. A report names the build it came from, so the ones at the
        // front of a full spool are the ones most likely to be about a build the
        // person has already replaced — and a spool that stayed full of them
        // would never carry a report about the build that is actually installed.
        for name in names.prefix(names.count - limit) {
            try FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    private func createDirectoryIfNeeded() throws {
        let fileManager = FileManager.default
        let path = directory.path(percentEncoded: false)
        guard !fileManager.fileExists(atPath: path) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw CrashReportSpoolError.couldNotCreateDirectory(path: path)
        }
    }
}

// MARK: - In memory

/// A spool that keeps reports in memory and writes nothing.
///
/// The double for tests and previews. It enforces the same capacity and the same
/// replace-on-equal-digest behaviour as the file-backed one, because a double
/// that accepted reports the real spool would evict is a double that makes the
/// bound untested.
package final class InMemoryCrashReportSpool: CrashReportSpooling {

    package let capacity: Int

    private let state = OSAllocatedUnfairLock(initialState: [CrashReport]())

    /// Set to throw from ``store(_:)``, to exercise a failing spool.
    private let failure = OSAllocatedUnfairLock<CrashReportSpoolError?>(initialState: nil)

    package init(capacity: Int = CrashReportLimits.standard.spoolCapacity) {
        precondition(capacity > 0, "A spool with no capacity would discard every crash.")
        self.capacity = capacity
    }

    /// What the spool holds, oldest payload window first.
    package var reports: [CrashReport] { state.withLock { $0 } }

    /// Makes every subsequent ``store(_:)`` throw `error`.
    package func failStores(with error: CrashReportSpoolError) {
        failure.withLock { $0 = error }
    }

    package func store(_ report: CrashReport) throws {
        if let error = failure.withLock({ $0 }) { throw error }
        let digest = report.digest
        state.withLock { current in
            current.removeAll { $0.digest == digest }
            current.append(report)
            current.sort { lhs, rhs in
                if lhs.windowEnd == rhs.windowEnd { return lhs.digest < rhs.digest }
                return lhs.windowEnd < rhs.windowEnd
            }
            if current.count > capacity {
                current.removeFirst(current.count - capacity)
            }
        }
    }

    package func stored() throws -> SpooledReports {
        SpooledReports(reports: reports)
    }

    package func discard(digest: String) throws {
        state.withLock { current in
            current.removeAll { $0.digest == digest }
        }
    }
}
