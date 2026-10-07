import Foundation
import os

// MARK: - What a server did with a report

/// What came back from an attempt to hand one report over.
///
/// Three cases, and the third is the one the design turns on. A queue that
/// distinguishes only success from failure has to pick one wrong behaviour for
/// a report the server will never accept: retry it forever, in which case one
/// malformed report blocks every later one behind it, or delete it on any
/// failure, in which case a day with no network costs every crash in it.
///
/// The split is the ordinary HTTP one and is made by the uploader, because the
/// uploader is the only layer that can see the status code.
package enum CrashReportUploadOutcome: Sendable, Equatable {

    /// The server took it. Forget the report.
    case accepted

    /// The server refused it and will refuse it again — a 4xx that is not 408 or
    /// 429. Forget the report: a report nothing will accept is one that can only
    /// occupy the queue.
    case rejected(reason: String)

    /// Nothing is wrong with the report; the attempt failed. Keep it and try on
    /// a later launch.
    case deferred(reason: String)

    /// Whether the report has done its job and can leave the spool.
    ///
    /// `accepted` and `rejected` both clear it, which is why this is one property
    /// rather than two comparisons at the call site: the two reasons for dropping
    /// a report are opposite in meaning and identical in consequence, and a
    /// drain loop that spelled them separately would eventually handle one.
    package var clearsSpool: Bool {
        switch self {
        case .accepted, .rejected: true
        case .deferred: false
        }
    }
}

// MARK: - The seam

/// Hands one report to wherever reports go.
///
/// One report per call rather than a batch. A batch is one request for a day's
/// worth of crashes, which is cheaper — and it makes a partial success
/// unrepresentable: the server accepted nine of ten and the client has one
/// outcome to act on, so it either re-sends nine accepted reports or drops one
/// that was never stored. Per-report calls make every outcome exact, and the
/// cost is bounded by ``CrashReportLimits/maxReportsPerPayload``.
///
/// It lives in `Core` with no mention of HTTP, so `Core` describes the pipeline
/// and `Networking` is the only target that can send anything. That is also what
/// keeps `Core`'s privacy manifest able to say it collects nothing: collection is
/// transmission, and nothing here transmits.
package protocol CrashReportUploading: Sendable {

    /// Attempts delivery of `report`.
    ///
    /// Returns an outcome rather than throwing, because every failure here is a
    /// routine fact the queue has a policy for, and `throws` would collapse the
    /// 400 and the timeout back into one case. An uploader that genuinely cannot
    /// classify a failure returns ``CrashReportUploadOutcome/deferred(reason:)``,
    /// which is the safe direction: the report stays.
    func upload(_ report: CrashReport) async -> CrashReportUploadOutcome
}

// MARK: - Events

/// Something the crash-reporting pipeline did.
///
/// Named states rather than log strings, so the reporter decides the wording and
/// a test can assert on what happened. The set is deliberately the set a person
/// debugging this pipeline asks about: did anything arrive, did it reach disk,
/// did it leave, and what is stuck.
package enum CrashReportingEvent: Sendable, Equatable {

    /// A payload arrived and was projected into this many reports.
    ///
    /// `dropped` is how many diagnostics the payload held beyond
    /// ``CrashReportLimits/maxReportsPerPayload``. It is the one number here
    /// that reports data loss, so it is carried rather than left to be inferred
    /// from a count that looks plausible.
    case received(reports: Int, dropped: Int)

    /// A report reached the spool.
    case spooled(digest: String, summary: String)

    /// A report could not be spooled, so it is gone. The worst event here.
    case spoolFailed(summary: String, error: String)

    /// A drain finished. Counts, so one line answers "is the queue moving?".
    case drained(accepted: Int, rejected: Int, deferred: Int, remaining: Int)

    /// Spooled files could not be decoded and were deleted.
    case discardedUnreadable(count: Int)

    /// The spool itself could not be read, so this drain did nothing.
    ///
    /// Distinct from a drain that found an empty queue, which is the ordinary
    /// case and looks identical in any count-based report. The two want opposite
    /// reactions — one is the pipeline working — so they are two events.
    case spoolReadFailed(error: String)

    /// A drain was asked for while one was running, and did nothing.
    case drainAlreadyRunning
}

/// Where crash-reporting events go.
package protocol CrashReportingReporter: Sendable {
    func report(_ event: CrashReportingEvent)
}

// MARK: - The unified log

/// The default reporter: the unified log, under the app's own subsystem.
///
/// Levels are chosen so that the two states nobody can distinguish without them
/// are the two that survive at default verbosity. "Nothing arrived" and "the
/// pipeline is not running" look identical in a log that only speaks when a
/// report appears, so a drain that found nothing is `.debug` while a payload
/// arriving is `.notice`. A report that could not be spooled is `.fault`: it is
/// the one event in this enum that means data was lost.
///
/// Every interpolation is `.public`, and that is a decision rather than an
/// oversight. What these lines carry is a digest, a build number, a count and an
/// error description — nothing about the person using the app — and a crash
/// pipeline whose log is redacted to `<private>` on the device of the one tester
/// who can reproduce the bug is a pipeline with no diagnostics.
package struct OSLogCrashReporter: CrashReportingReporter {
    private let logger: Logger

    package init(subsystem: String) {
        logger = Logger(subsystem: subsystem, category: "crash-reporting")
    }

    package func report(_ event: CrashReportingEvent) {
        switch event {
        case .received(let reports, let dropped):
            logger.notice("Payload: \(reports, privacy: .public) report(s), \(dropped, privacy: .public) dropped")
        case .spooled(let digest, let summary):
            logger.notice("Spooled \(digest, privacy: .public): \(summary, privacy: .public)")
        case .spoolFailed(let summary, let error):
            logger.fault("Lost a report (\(summary, privacy: .public)): \(error, privacy: .public)")
        case .drained(let accepted, let rejected, let held, let remaining):
            log(accepted: accepted, rejected: rejected, held: held, remaining: remaining)
        case .discardedUnreadable(let count):
            logger.error("Discarded \(count, privacy: .public) unreadable spooled file(s)")
        case .spoolReadFailed(let error):
            logger.error("Could not read the spool: \(error, privacy: .public)")
        case .drainAlreadyRunning:
            logger.debug("A drain is already running; this one did nothing")
        }
    }

    /// One line per drain, and `.debug` when there was nothing to do.
    ///
    /// Not `.notice` unconditionally: a drain runs at every launch and most of
    /// them have an empty queue, so an unconditional line would put one entry per
    /// launch between a reader and the drain that mattered.
    private func log(accepted: Int, rejected: Int, held: Int, remaining: Int) {
        guard accepted + rejected + held > 0 else {
            logger.debug("Nothing to upload")
            return
        }
        logger.notice("Drained: \(accepted, privacy: .public) accepted, \(rejected, privacy: .public) rejected")
        logger.notice("Held: \(held, privacy: .public) deferred, \(remaining, privacy: .public) waiting")
    }
}

// MARK: - Doubles

/// A reporter that keeps what it was told, for tests and previews.
package final class RecordingCrashReporter: CrashReportingReporter {
    private let state = OSAllocatedUnfairLock(initialState: [CrashReportingEvent]())

    package init() {}

    /// Everything reported so far, in order.
    package var events: [CrashReportingEvent] { state.withLock { $0 } }

    package func report(_ event: CrashReportingEvent) {
        state.withLock { $0.append(event) }
    }
}

/// An uploader that records what it was asked to send and answers from a script.
///
/// The script is a closure rather than a stubbed single outcome, because the
/// behaviour worth testing is per-report: a queue of three where the middle one
/// is rejected has to come out as one remaining, and a stub that answers the same
/// way every time cannot express that.
package final class RecordingCrashReportUploader: CrashReportUploading {

    package typealias Handler = @Sendable (CrashReport) -> CrashReportUploadOutcome

    private struct State: Sendable {
        var handler: Handler = { _ in .accepted }
        var uploaded: [CrashReport] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package init() {}

    /// Every report handed over, in order, including re-attempts.
    package var uploaded: [CrashReport] { state.withLock { $0.uploaded } }

    /// The digests handed over, in order.
    package var uploadedDigests: [String] { uploaded.map(\.digest) }

    /// Decides what each report's attempt returns.
    package var handler: Handler {
        get { state.withLock { $0.handler } }
        set { state.withLock { $0.handler = newValue } }
    }

    package func upload(_ report: CrashReport) async -> CrashReportUploadOutcome {
        state.withLock { current in
            current.uploaded.append(report)
            return current.handler(report)
        }
    }
}
