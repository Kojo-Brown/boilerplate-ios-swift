import Foundation
import Testing
@testable import Core

/// What CI can assert about instrumentation that nothing in CI can read.
///
/// An Instruments trace needs a device, a window server and a person looking
/// at it, and none of those exist on a runner. What does survive the trip is
/// the contract the markers keep, and that is where this kind of code actually
/// breaks: an interval that is opened and never closed is not a missing
/// measurement, it is a *wrong* one — Instruments draws it as a region running
/// to the end of the trace, which looks like the hang somebody opened the
/// trace to find.
@Suite("Performance tracing")
struct PerformanceTraceTests {

    private struct StubFailure: Error {}

    // MARK: - The interval contract

    @Test("An interval opened around work is closed when the work returns")
    func measureClosesTheIntervalItOpened() {
        let tracer = RecordingTracer()

        let value = tracer.measure(.searchScan) { 42 }

        #expect(value == 42)
        #expect(tracer.beginCount(of: .searchScan) == 1)
        #expect(tracer.endCount(of: .searchScan) == 1)
        #expect(tracer.unclosedIDs.isEmpty)
    }

    @Test("An interval is closed when the work throws, and the error still escapes")
    func measureClosesTheIntervalWhenTheWorkThrows() {
        let tracer = RecordingTracer()

        #expect(throws: StubFailure.self) {
            _ = try tracer.measure(.homeLoad) { () -> Int in throw StubFailure() }
        }

        #expect(tracer.beginCount(of: .homeLoad) == 1)
        #expect(tracer.endCount(of: .homeLoad) == 1)
        #expect(tracer.unclosedIDs.isEmpty)
    }

    @Test("Nested intervals close inside out and never share an identifier")
    func nestedIntervalsAreDistinct() {
        let tracer = RecordingTracer()

        tracer.measure(.homeLoad) {
            tracer.measure(.searchIndexBuild) {
                tracer.emit(.searchScan)
            }
        }

        #expect(tracer.unclosedIDs.isEmpty)
        #expect(tracer.emitCount(of: .searchScan) == 1)
        #expect(tracer.records.count == 5)
        #expect(tracer.records.first?.opened == .homeLoad)
        #expect(tracer.records.last?.closed == .homeLoad)
    }

    /// The point of the lock. A tracer is handed to whatever is being
    /// measured, and some of that work is deliberately not on the main actor —
    /// `SearchIndex` is `Sendable` so that a large corpus can be folded off it.
    /// Two intervals sharing an identifier are one interval in the trace, of
    /// the wrong duration.
    @Test("Identifiers stay distinct when intervals are opened concurrently")
    func concurrentBeginsIssueDistinctIdentifiers() async {
        let tracer = RecordingTracer()
        let opens = 200

        let issued = await withTaskGroup(of: UInt64.self) { group in
            for _ in 0..<opens {
                group.addTask { tracer.begin(.searchScan).id }
            }
            var ids: Set<UInt64> = []
            for await id in group { ids.insert(id) }
            return ids
        }

        #expect(issued.count == opens)
        #expect(tracer.unclosedIDs.count == opens)
    }

    // MARK: - Off

    @Test("The no-op tracer runs the work and records nothing")
    func noOpTracerIsTransparent() {
        let tracer = NoOpTracer()

        let value = tracer.measure(.homeLoad) { "unchanged" }

        #expect(value == "unchanged")
    }

    // MARK: - The live one

    /// A smoke test rather than a measurement: what `os_signpost` did with the
    /// markers is not readable from inside the process, so what is left to
    /// assert is that the identifiers it pairs begins and ends by are the ones
    /// this type promises — distinct per interval, and never `0`, which is
    /// `OSSignpostID.null` and would not be paired at all.
    @Test("The signpost tracer issues a distinct non-null identifier per interval")
    func signpostTracerIssuesUsableIdentifiers() {
        let tracer = SignpostTracer(subsystem: "com.example.boilerplate-ios-swift.tests")

        let first = tracer.begin(.homeLoad)
        let second = tracer.begin(.homeLoad)
        tracer.end(second)
        tracer.end(first)
        tracer.emit(.searchScan)

        #expect(first.id != second.id)
        #expect(first.id > 0)
        #expect(second.id > 0)
        #expect(first.point == .homeLoad)
    }

    /// Every case has a signpost name, and the switch that gives it one is
    /// exhaustive — a case added without a name does not compile. This asserts
    /// the other half: that the vocabulary a trace is read with is not empty
    /// and carries no duplicates, since two points sharing a name are one
    /// track in Instruments.
    @Test("Every trace point has a distinct raw value")
    func tracePointsAreDistinct() {
        let rawValues = TracePoint.allCases.map(\.rawValue)

        #expect(!rawValues.isEmpty)
        #expect(Set(rawValues).count == rawValues.count)
    }
}
