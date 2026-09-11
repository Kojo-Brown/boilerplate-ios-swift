import Foundation
import os

// MARK: - What is traced

/// A named region of work the app wants to see in an Instruments trace.
///
/// A closed enum rather than a free-form string, for the same reason
/// `RepositoryOperation` is one: a trace that a tool has to read is a
/// vocabulary, not prose. Three things follow from spelling it this way.
///
/// * Instruments groups intervals by name, so a typo does not produce a
///   mis-spelled row — it produces a *second* row that looks empty, which is
///   the kind of measurement error that reads as "the fix worked".
/// * ``SignpostTracer`` maps each case to a `StaticString` in one exhaustive
///   switch, so adding a case is a compile error there rather than a silent
///   omission from the trace.
/// * A test can assert against a value. `RecordingTracer` records these cases,
///   and `SearchHotspotTests` asserts on them.
///
/// The set is deliberately small. A signpost costs very little but is not
/// free, and a trace with an interval around everything is as unreadable as
/// one with an interval around nothing.
package enum TracePoint: String, Sendable, CaseIterable {

    /// The home screen's fetch, from the first byte requested to the rows
    /// being handed to the view model. Covers the `await`, so it is the
    /// interval to compare against the hitch you are looking at.
    case homeLoad

    /// Folding one corpus of rows into the search keys ``SearchIndex`` matches
    /// against. Fires once per change to the corpus.
    case searchIndexBuild

    /// One pass of the search index over the corpus. Before Phase 10 item 3
    /// this fired four times per keystroke; the whole point of
    /// ``MemoizedSearch`` is that it now fires once.
    case searchScan
}

/// The receipt ``PerformanceTracing/begin(_:)`` hands back, to be given to
/// ``PerformanceTracing/end(_:)``.
///
/// It carries the point as well as the identifier so that `end` needs no
/// second argument and cannot be passed the wrong name: the pairing is the
/// value, rather than a convention the call site has to keep.
package struct TraceHandle: Sendable, Hashable {

    package let point: TracePoint

    /// Distinguishes concurrently open intervals with the same name. Instruments
    /// needs it: two `homeLoad` intervals overlapping without distinct
    /// identifiers are reported as one interval of the wrong duration.
    package let id: UInt64

    package init(point: TracePoint, id: UInt64) {
        self.point = point
        self.id = id
    }
}

// MARK: - The seam

/// Emits interval and point markers for a profiler.
///
/// The protocol exists so that the app can be instrumented without the tests
/// having to read an Instruments trace — which nothing in CI can do, on a
/// runner with no window server and no device. What CI *can* hold the
/// instrumentation to is its contract, and that contract is where the bugs in
/// this kind of code live: an interval that is begun and never ended shows up
/// in Instruments as a region that runs to the end of the trace, which reads
/// as a hang that is not there.
///
/// **Non-throwing and non-`async`**, so that measuring something cannot change
/// when it runs. An `async` `begin` would be a suspension point in the middle
/// of the work being measured, and the measurement would include the wait for
/// whatever the tracer wanted to do.
package protocol PerformanceTracing: Sendable {

    /// Opens an interval and returns its receipt.
    func begin(_ point: TracePoint) -> TraceHandle

    /// Closes the interval `handle` was opened for.
    func end(_ handle: TraceHandle)

    /// Marks an instant rather than a span.
    func emit(_ point: TracePoint)
}

extension PerformanceTracing {

    /// Runs `work` inside an interval, closing it however `work` leaves.
    ///
    /// `defer` rather than a line after the call, because the failure mode
    /// this type has is an interval that is never closed, and the three ways
    /// out of a synchronous body — return, `throw`, and a `guard` in a nested
    /// scope — are exactly the three a trailing line misses.
    ///
    /// There is deliberately no `async` overload. Overloading on `async` puts
    /// the compiler in charge of which one a call means, and the call sites
    /// that need it here are two lines of `begin`/`defer`/`end` that say
    /// plainly where the interval ends — see `HomeViewModel.loadItems()`,
    /// where the interval has to survive a cancellation as well as a throw.
    package func measure<Result>(
        _ point: TracePoint,
        around work: () throws -> Result
    ) rethrows -> Result {
        let handle = begin(point)
        defer { end(handle) }
        return try work()
    }
}

// MARK: - Off

/// A tracer that records nothing.
///
/// The default everywhere a tracer is optional, so that a type under test and
/// a type in a `#Preview` need no ceremony, and so that "not instrumented" is
/// a value rather than an `if let` at every call site.
package struct NoOpTracer: PerformanceTracing {

    package init() {}

    package func begin(_ point: TracePoint) -> TraceHandle {
        TraceHandle(point: point, id: 0)
    }

    package func end(_ handle: TraceHandle) {}

    package func emit(_ point: TracePoint) {}
}

// MARK: - Double

/// What a ``RecordingTracer`` saw, in the order it saw it.
package enum TraceRecord: Sendable, Equatable {
    case began(TracePoint, id: UInt64)
    case ended(TracePoint, id: UInt64)
    case emitted(TracePoint)

    /// The point this record opened an interval for, or `nil` if it did not.
    package var opened: TracePoint? {
        if case .began(let point, _) = self { return point }
        return nil
    }

    /// The point this record closed an interval for, or `nil` if it did not.
    package var closed: TracePoint? {
        if case .ended(let point, _) = self { return point }
        return nil
    }
}

/// Keeps every marker in memory for a test to read back.
///
/// Lock-backed rather than `@unchecked Sendable` over a bare array, which is
/// the discipline `SendableConformanceTests` holds this package's doubles to.
/// It matters more here than usual: a tracer is handed to whatever is being
/// measured, and some of that work is deliberately not on the main actor.
package final class RecordingTracer: PerformanceTracing {

    private struct State {
        var records: [TraceRecord] = []
        var nextID: UInt64 = 1
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package init() {}

    /// Every marker recorded so far, oldest first.
    package var records: [TraceRecord] {
        state.withLock { $0.records }
    }

    /// How many intervals of `point` were opened.
    package func beginCount(of point: TracePoint) -> Int {
        records.filter { $0.opened == point }.count
    }

    /// How many intervals of `point` were closed.
    package func endCount(of point: TracePoint) -> Int {
        records.filter { $0.closed == point }.count
    }

    /// How many instants of `point` were marked.
    package func emitCount(of point: TracePoint) -> Int {
        records.filter { $0 == .emitted(point) }.count
    }

    /// The identifiers that were opened and never closed.
    ///
    /// The assertion worth making about instrumentation, and the one a count
    /// of intervals does not make: an interval left open is a shape in the
    /// trace that looks like the problem being hunted.
    package var unclosedIDs: [UInt64] {
        let snapshot = records
        var open: [UInt64] = []
        for record in snapshot {
            switch record {
            case .began(_, let id):
                open.append(id)
            case .ended(_, let id):
                open.removeAll { $0 == id }
            case .emitted:
                continue
            }
        }
        return open
    }

    /// Drops every record, so a measurement can start from a settled state
    /// rather than from process launch.
    package func reset() {
        state.withLock { $0.records.removeAll(keepingCapacity: true) }
    }

    package func begin(_ point: TracePoint) -> TraceHandle {
        let id = state.withLock { current -> UInt64 in
            let issued = current.nextID
            current.nextID &+= 1
            current.records.append(.began(point, id: issued))
            return issued
        }
        return TraceHandle(point: point, id: id)
    }

    package func end(_ handle: TraceHandle) {
        state.withLock { $0.records.append(.ended(handle.point, id: handle.id)) }
    }

    package func emit(_ point: TracePoint) {
        state.withLock { $0.records.append(.emitted(point)) }
    }
}
