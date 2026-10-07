import Foundation
import Testing
@testable import Core
@testable import Networking

// MARK: - Ingest

@Suite("Accepting a payload is synchronous, because MetricKit delivers once")
struct CrashReportPipelineIngestTests {

    /// The assertion the whole feature rests on: by the time `accept` returns, the
    /// reports are in the spool. No `await` anywhere in this test — if `accept`
    /// ever becomes `async`, this stops compiling, which is the point.
    @Test("The reports are spooled by the time accept returns")
    func acceptIsDurableBeforeItReturns() {
        let spool = InMemoryCrashReportSpool()
        let pipeline = makePipeline(spool: spool)

        pipeline.accept([CrashReportFixture.crash(), CrashReportFixture.hang()])

        #expect(spool.reports.count == 2)
    }

    @Test("What was spooled is reported, so a silent pipeline is visible")
    func spooledReportsAreAnnounced() {
        let reporter = RecordingCrashReporter()
        let report = CrashReportFixture.crash()
        let pipeline = makePipeline(reporter: reporter)

        pipeline.accept([report])

        #expect(reporter.events.contains(.received(reports: 1, dropped: 0)))
        #expect(reporter.events.contains(.spooled(digest: report.digest, summary: report.summary)))
    }

    /// An empty payload still reports, because "nothing arrived" and "the pipeline
    /// is not running" are the two states this feature spends its life between and
    /// a reporter that only speaks when there is a crash cannot tell them apart.
    @Test("An empty payload is still reported")
    func emptyPayloadIsAnnounced() {
        let reporter = RecordingCrashReporter()
        makePipeline(reporter: reporter).accept([])
        #expect(reporter.events == [.received(reports: 0, dropped: 0)])
    }

    /// The cap is the one place in the pipeline that discards on purpose, so the
    /// count of what it discarded has to leave the building. Without it a device
    /// that crashed two hundred times is indistinguishable from one that crashed
    /// sixty-four.
    @Test("Reports past the per-payload cap are dropped and counted")
    func perPayloadCapIsReported() {
        let reporter = RecordingCrashReporter()
        let spool = InMemoryCrashReportSpool()
        let limits = CrashReportLimits(maxReportsPerPayload: 3)
        let pipeline = makePipeline(spool: spool, reporter: reporter, limits: limits)

        pipeline.accept(CrashReportFixture.series(count: 5))

        #expect(reporter.events.contains(.received(reports: 3, dropped: 2)))
        #expect(spool.reports.count == 3)
    }

    /// Stopping at the first unwritable report would turn one bad file into a lost
    /// payload, so the loop continues — and every loss is reported as a fault,
    /// because this is the only event in the pipeline that means data is gone.
    @Test("A spool failure loses one report, is reported, and does not stop the rest")
    func spoolFailureIsReportedPerReport() {
        let reporter = RecordingCrashReporter()
        let spool = InMemoryCrashReportSpool()
        spool.failStores(with: .couldNotCreateDirectory(path: "/nowhere"))
        let pipeline = makePipeline(spool: spool, reporter: reporter)

        pipeline.accept(CrashReportFixture.series(count: 3))

        let failures = reporter.events.filter { event in
            if case .spoolFailed = event { return true }
            return false
        }
        #expect(failures.count == 3)
        #expect(spool.reports.isEmpty)
    }

    private func makePipeline(
        spool: InMemoryCrashReportSpool = InMemoryCrashReportSpool(),
        uploader: RecordingCrashReportUploader = RecordingCrashReportUploader(),
        reporter: RecordingCrashReporter = RecordingCrashReporter(),
        limits: CrashReportLimits = .standard
    ) -> CrashReportPipeline {
        CrashReportPipeline(spool: spool, uploader: uploader, reporter: reporter, limits: limits)
    }
}

// MARK: - Drain

@Suite("Draining clears what is done and keeps what is not")
struct CrashReportPipelineDrainTests {

    @Test("An accepted report leaves the spool")
    func acceptedReportsAreCleared() async throws {
        let spool = InMemoryCrashReportSpool()
        let uploader = RecordingCrashReportUploader()
        let pipeline = CrashReportPipeline(spool: spool, uploader: uploader, reporter: quiet())
        pipeline.accept(CrashReportFixture.series(count: 3))

        await pipeline.drain()

        #expect(uploader.uploadedDigests.count == 3)
        #expect(spool.reports.isEmpty)
    }

    /// The case a two-state queue cannot handle: a report the server will never
    /// accept. Kept, it blocks every later report for the life of the install;
    /// dropped on any failure, a day offline costs every crash in it. So the
    /// outcome says which, and a rejection clears the spool exactly like a success.
    @Test("A rejected report leaves the spool rather than blocking it")
    func rejectedReportsAreCleared() async throws {
        let spool = InMemoryCrashReportSpool()
        let uploader = RecordingCrashReportUploader()
        uploader.handler = { _ in .rejected(reason: "HTTP 400") }
        let pipeline = CrashReportPipeline(spool: spool, uploader: uploader, reporter: quiet())
        pipeline.accept(CrashReportFixture.series(count: 2))

        await pipeline.drain()

        #expect(spool.reports.isEmpty)
    }

    @Test("A deferred report stays, and is offered again on the next drain")
    func deferredReportsSurviveAndRetry() async throws {
        let spool = InMemoryCrashReportSpool()
        let uploader = RecordingCrashReportUploader()
        uploader.handler = { _ in .deferred(reason: "offline") }
        let pipeline = CrashReportPipeline(spool: spool, uploader: uploader, reporter: quiet())
        pipeline.accept([CrashReportFixture.crash()])

        await pipeline.drain()
        #expect(spool.reports.count == 1)

        uploader.handler = { _ in .accepted }
        await pipeline.drain()
        #expect(spool.reports.isEmpty)
    }

    /// A deferral is a statement about the connection, not about the report, so
    /// carrying on down the queue would cost one failing round trip per waiting
    /// report and change nothing. The queue keeps its order for the next launch.
    @Test("A deferral stops the drain instead of trying every report")
    func deferralStopsTheDrain() async throws {
        let spool = InMemoryCrashReportSpool()
        let uploader = RecordingCrashReportUploader()
        uploader.handler = { _ in .deferred(reason: "offline") }
        let pipeline = CrashReportPipeline(spool: spool, uploader: uploader, reporter: quiet())
        pipeline.accept(CrashReportFixture.series(count: 5))

        await pipeline.drain()

        #expect(uploader.uploadedDigests.count == 1)
        #expect(spool.reports.count == 5)
    }

    @Test("The front of the queue goes first, oldest window first")
    func drainIsInQueueOrder() async throws {
        let spool = InMemoryCrashReportSpool()
        let uploader = RecordingCrashReportUploader()
        let series = CrashReportFixture.series(count: 4)
        let pipeline = CrashReportPipeline(spool: spool, uploader: uploader, reporter: quiet())
        pipeline.accept(Array(series.reversed()))

        await pipeline.drain()

        #expect(uploader.uploadedDigests == series.map(\.digest))
    }

    @Test("A drain reports what it did")
    func drainCountsAreReported() async throws {
        let reporter = RecordingCrashReporter()
        let uploader = RecordingCrashReportUploader()
        let series = CrashReportFixture.series(count: 3)
        uploader.handler = { report in
            report.digest == series[1].digest ? .rejected(reason: "HTTP 422") : .accepted
        }
        let pipeline = CrashReportPipeline(
            spool: InMemoryCrashReportSpool(),
            uploader: uploader,
            reporter: reporter
        )
        pipeline.accept(series)

        await pipeline.drain()

        let drained = CrashReportingEvent.drained(
            accepted: 2,
            rejected: 1,
            deferred: 0,
            remaining: 0
        )
        #expect(reporter.events.contains(drained))
    }

    @Test("Pending counts what is waiting")
    func pendingCountsTheQueue() async throws {
        let uploader = RecordingCrashReportUploader()
        uploader.handler = { _ in .deferred(reason: "offline") }
        let pipeline = CrashReportPipeline(
            spool: InMemoryCrashReportSpool(),
            uploader: uploader,
            reporter: quiet()
        )
        pipeline.accept(CrashReportFixture.series(count: 2))

        #expect(await pipeline.pending() == 2)
    }

    /// The reentrancy that the `draining` flag closes.
    ///
    /// An actor serialises synchronous access, not whole method bodies: at every
    /// `await` it is free to run another job, and `drain()` awaits per report. So
    /// two drains — one from launch, one from a scene becoming active a moment
    /// later — would interleave at the first suspension, read the same spool
    /// contents, and upload every report twice. The version of the pipeline
    /// without the flag passes every other test in this suite.
    ///
    /// The overlap is forced rather than hoped for. The uploader parks inside its
    /// first upload, which leaves the pipeline's actor free, so the second
    /// `drain()` is awaited *directly* from the test: it enters while the first is
    /// still in flight, every time, with no sleeping and nothing to race.
    @Test("Two concurrent drains upload each report once")
    func concurrentDrainsDoNotDoubleSend() async throws {
        let spool = InMemoryCrashReportSpool()
        let uploader = SlowCrashReportUploader()
        let reporter = RecordingCrashReporter()
        let pipeline = CrashReportPipeline(spool: spool, uploader: uploader, reporter: reporter)
        pipeline.accept(CrashReportFixture.series(count: 3))

        let firstDrain = Task { await pipeline.drain() }
        await uploader.waitUntilFirstUploadStarted()

        // The first drain is parked inside an upload and has already set its
        // flag, so this one has to be turned away rather than reading the spool.
        await pipeline.drain()
        #expect(reporter.events.contains(.drainAlreadyRunning))

        await uploader.release()
        await firstDrain.value

        let sent = await uploader.uploadedDigests
        #expect(sent.count == 3)
        #expect(Set(sent).count == 3)
        #expect(spool.reports.isEmpty)
    }

    private func quiet() -> RecordingCrashReporter { RecordingCrashReporter() }
}

// MARK: - The uploader's classification

@Suite("The uploader decides what is permanent and what is worth retrying")
struct APICrashReportUploaderTests {

    /// The normal path for this endpoint, not a defensive branch: `sendEmpty`
    /// decodes `EmptyResponse` from the body, an empty body is not valid JSON, and
    /// the right answer to "here is a crash report" is 204.
    @Test("A 2xx whose body cannot be decoded counts as accepted")
    func emptyBodyIsAccepted() {
        #expect(APICrashReportUploader.outcome(for: .decodingFailed("no data")) == .accepted)
    }

    @Test("4xx is permanent, except for the two codes that ask for a retry")
    func clientErrorsArePermanentUnlessTheyAskForRetry() {
        for code in [400, 403, 404, 413, 422] {
            let outcome = APICrashReportUploader.outcome(for: .httpError(statusCode: code, data: Data()))
            #expect(outcome.clearsSpool, "HTTP \(code) should clear the spool")
        }
        for code in [408, 429] {
            let outcome = APICrashReportUploader.outcome(for: .httpError(statusCode: code, data: Data()))
            #expect(!outcome.clearsSpool, "HTTP \(code) asks to be retried")
        }
    }

    @Test("5xx keeps the report")
    func serverErrorsAreDeferred() {
        let outcome = APICrashReportUploader.outcome(for: .httpError(statusCode: 503, data: Data()))
        #expect(outcome == .deferred(reason: "HTTP 503"))
    }

    /// The request is unauthenticated by design, so a 401 is the endpoint refusing
    /// the report rather than a token a refresh could fix — and the transport does
    /// not attempt a refresh for a request with `requiresAuth: false`, so deferring
    /// would retry the identical request forever.
    @Test("A 401 is permanent here, unlike everywhere else in the app")
    func unauthorizedIsPermanent() {
        #expect(APICrashReportUploader.outcome(for: .unauthorized).clearsSpool)
    }

    @Test("A network failure keeps the report")
    func networkFailuresAreDeferred() {
        let error = APIError.networkUnavailable(URLError(.notConnectedToInternet))
        #expect(!APICrashReportUploader.outcome(for: error).clearsSpool)
    }

    @Test("A report is posted unauthenticated, keyed by its digest, to one path")
    func endpointIsUnauthenticatedAndKeyed() async throws {
        let client = MockAPIClient()
        let report = CrashReportFixture.crash()
        let seen = SentEndpoint()
        client.handler = { endpoint in
            await seen.record(endpoint)
            return EmptyResponse()
        }

        let outcome = await APICrashReportUploader(client: client).upload(report)

        let endpoint = try #require(await seen.endpoint)
        #expect(outcome == .accepted)
        #expect(endpoint.path == APICrashReportUploader.path)
        #expect(endpoint.method == .post)
        #expect(!endpoint.requiresAuth)
        #expect(endpoint.idempotencyKey?.rawValue == report.digest)
    }

    /// The body is the report and nothing else, which is the half of the privacy
    /// answer that no manifest can state: a declaration says what is sent, this
    /// says that nothing else is.
    @Test("The body decodes back to the report that was handed over")
    func bodyIsTheReport() async throws {
        let client = MockAPIClient()
        let report = CrashReportFixture.hang()
        let seen = SentEndpoint()
        client.handler = { endpoint in
            await seen.record(endpoint)
            return EmptyResponse()
        }

        _ = await APICrashReportUploader(client: client).upload(report)

        let body = try #require(await seen.endpoint?.body)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(CrashReport.self, from: body) == report)
    }
}

// MARK: - Doubles for this suite

/// An uploader that parks inside the first upload until it is released.
///
/// The only way to make two drains genuinely overlap: a stub that returned
/// immediately would let the first drain finish before the second started, and the
/// test would pass against a pipeline with no reentrancy guard at all.
private actor SlowCrashReportUploader: CrashReportUploading {
    private var digests: [String] = []
    private var started: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private var hasStarted = false

    var uploadedDigests: [String] { digests }

    /// Returns once an upload is in flight.
    func waitUntilFirstUploadStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            started = continuation
        }
    }

    /// Lets the parked upload — and every later one — through.
    func release() {
        isReleased = true
        gate?.resume()
        gate = nil
    }

    func upload(_ report: CrashReport) async -> CrashReportUploadOutcome {
        digests.append(report.digest)
        if !hasStarted {
            hasStarted = true
            started?.resume()
            started = nil
        }
        if !isReleased {
            await withCheckedContinuation { continuation in
                gate = continuation
            }
        }
        return .accepted
    }
}

/// Keeps the endpoint a `MockAPIClient` was handed.
///
/// An actor rather than a captured `var`, because `MockAPIClient.handler` is
/// `@Sendable`: a closure writing to a local would not compile, and one writing
/// through a lock would be a second lock in a test about an uploader.
private actor SentEndpoint {
    private(set) var endpoint: APIEndpoint?

    func record(_ endpoint: APIEndpoint) {
        self.endpoint = endpoint
    }
}
