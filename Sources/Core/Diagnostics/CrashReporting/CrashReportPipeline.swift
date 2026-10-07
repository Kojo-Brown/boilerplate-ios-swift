import Foundation

/// Accepts projected diagnostics, makes them durable, and drains them to a
/// server.
///
/// ```swift
/// // From MetricKit's callback — synchronous, so nothing is lost if the
/// // process ends a moment later.
/// pipeline.accept(reports)
/// // Later, on a launch with a network.
/// await pipeline.drain()
/// ```
///
/// ## The two halves, and why only one of them is on the actor
///
/// ``accept(_:)`` is `nonisolated` and synchronous. It has to be: MetricKit
/// delivers a payload exactly once, with no acknowledgement and no second
/// chance, so the write has to have happened by the time its callback returns.
/// An `isolated` `accept` would make every call site an `await`, and the natural
/// spelling of an `await` from a synchronous system callback is `Task { ... }` —
/// which returns before the write and hands a crash report's survival to the
/// scheduler. ``CrashReportSpooling`` carries the longer version of that
/// argument.
///
/// ``drain()`` is isolated, because uploading is the opposite kind of work:
/// network-bound, failure-prone, and with nothing lost by being late. Being on
/// the actor is also what makes "one upload of each report" expressible at all.
///
/// ## The reentrancy this closes
///
/// `drain()` is the textbook actor-reentrancy hazard, and it is spelled out here
/// because the version without ``draining`` compiles, passes any test that calls
/// it once, and uploads every report twice in production.
///
/// An actor serialises *synchronous* access, not whole method bodies: at every
/// `await` the actor is free to run another job. `drain()` awaits per report, so
/// a second `drain()` — one from launch, one from a scene becoming active a
/// moment later — interleaves at the first suspension, reads the same spool
/// contents the first drain has not finished clearing, and sends them again. The
/// flag is checked and set with no `await` between, so a second caller is turned
/// away before it can read anything, and it reports that it was.
///
/// Idempotency on the server is the belt to this braces — every upload carries
/// the report's digest as its key — but a client that knowingly double-sends and
/// relies on the other end to clean up is a client that costs its users' data
/// allowance for nothing.
package actor CrashReportPipeline {

    private let spool: any CrashReportSpooling
    private let uploader: any CrashReportUploading
    private let reporter: any CrashReportingReporter
    private let limits: CrashReportLimits

    /// Whether a drain is in flight. See the reentrancy note above.
    private var draining = false

    package init(
        spool: any CrashReportSpooling,
        uploader: any CrashReportUploading,
        reporter: any CrashReportingReporter,
        limits: CrashReportLimits = .standard
    ) {
        self.spool = spool
        self.uploader = uploader
        self.reporter = reporter
        self.limits = limits
    }

    // MARK: - Ingest

    /// Makes `reports` durable, returning only once they are.
    ///
    /// `nonisolated` and synchronous on purpose — see the type's documentation.
    /// It reaches only `let` properties of `Sendable` type, which is what lets it
    /// be both.
    ///
    /// Reports beyond ``CrashReportLimits/maxReportsPerPayload`` are dropped from
    /// the *end*, so what is kept is the oldest part of the window. The count of
    /// what was dropped is reported, because this is the one place in the
    /// pipeline where data is discarded on purpose and a silent cap is
    /// indistinguishable from a device that only crashed 64 times.
    ///
    /// A report that cannot be written is reported as `.spoolFailed` and the loop
    /// continues to the next one. Stopping at the first failure would turn one
    /// unwritable file into a lost payload.
    package nonisolated func accept(_ reports: [CrashReport]) {
        let kept = reports.prefix(limits.maxReportsPerPayload)
        reporter.report(.received(reports: kept.count, dropped: reports.count - kept.count))
        for report in kept {
            do {
                try spool.store(report)
                reporter.report(.spooled(digest: report.digest, summary: report.summary))
            } catch {
                reporter.report(
                    .spoolFailed(summary: report.summary, error: "\(error)")
                )
            }
        }
    }

    // MARK: - Drain

    /// Tries to hand every spooled report over, clearing the ones that are done.
    ///
    /// Stops at the first ``CrashReportUploadOutcome/deferred(reason:)`` rather
    /// than carrying on down the queue. A deferral means the transport is not
    /// working — no network, a 503, a timeout — and that is a property of the
    /// connection rather than of the report, so the next twenty attempts would
    /// fail the same way, cost twenty round trips, and change nothing. The queue
    /// keeps its order, and the next launch starts again from the front.
    ///
    /// Never throws and never cancels the work in the middle: a report whose
    /// upload is cancelled stays spooled, because `clearsSpool` is only consulted
    /// for an outcome that came back.
    package func drain() async {
        guard !draining else {
            reporter.report(.drainAlreadyRunning)
            return
        }
        draining = true
        defer { draining = false }

        let spooled: SpooledReports
        do {
            spooled = try spool.stored()
        } catch {
            reporter.report(.spoolReadFailed(error: "\(error)"))
            return
        }
        if spooled.unreadable > 0 {
            reporter.report(.discardedUnreadable(count: spooled.unreadable))
        }

        var accepted = 0
        var rejected = 0
        var deferred = 0
        for report in spooled.reports {
            let outcome = await uploader.upload(report)
            switch outcome {
            case .accepted: accepted += 1
            case .rejected: rejected += 1
            case .deferred: deferred += 1
            }
            guard outcome.clearsSpool else { break }
            try? spool.discard(digest: report.digest)
        }

        let remaining = spooled.reports.count - accepted - rejected
        reporter.report(
            .drained(
                accepted: accepted,
                rejected: rejected,
                deferred: deferred,
                remaining: remaining
            )
        )
    }

    /// How many reports are waiting. For a diagnostics screen and for tests.
    package func pending() -> Int {
        (try? spool.stored().reports.count) ?? 0
    }
}
