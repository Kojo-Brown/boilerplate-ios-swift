import Foundation
import os

/// The ``PerformanceTracing`` implementation that Instruments can see.
///
/// Every marker goes to the **Points of Interest** category, which is the one
/// Instruments surfaces without being configured: open any template, and the
/// app's own intervals are already on a track above the system's. That is the
/// difference between a trace you can read and one you have to correlate by
/// timestamp — a hitch at 00:04.312 means nothing until the track above it
/// says `HomeLoad` was open across it.
///
/// ## Why the identifier is issued here
///
/// `os_signpost` pairs a `.begin` with an `.end` by signpost identifier, and
/// the default — `.exclusive` — means "there is only ever one of these open at
/// a time". A view model that starts a load, is cancelled, and starts another
/// breaks that promise, and the trace shows one long interval rather than two
/// short ones: a hang that never happened. So each ``begin(_:)`` issues its
/// own identifier and ``TraceHandle`` carries it to the matching `end`.
///
/// Identifiers start at 1 and only ever increase. `0` is `OSSignpostID.null`,
/// and `UInt64.max` is `.invalid`; neither would be paired.
///
/// ## Why `@unchecked Sendable`
///
/// `os_signpost` is safe to call from any thread — that is the entire point of
/// it as a profiling primitive, since the interesting work is rarely on one
/// thread — and the mutable state here is one counter behind a lock. The
/// unchecked conformance covers the `OSLog` handle, which the compiler cannot
/// be told about and which is immutable and thread-safe by contract.
package final class SignpostTracer: PerformanceTracing, @unchecked Sendable {

    private let log: OSLog
    private let nextID = OSAllocatedUnfairLock<UInt64>(initialState: 1)

    /// - Parameter subsystem: Usually the value the composition root uses for
    ///   its other logging, so that one filter finds everything the app
    ///   emitted. See `AppContainer.logSubsystem` for why it is stated there
    ///   rather than read from the bundle.
    package init(subsystem: String) {
        log = OSLog(subsystem: subsystem, category: .pointsOfInterest)
    }

    package func begin(_ point: TracePoint) -> TraceHandle {
        let handle = TraceHandle(point: point, id: issueID())
        guard log.signpostsEnabled else { return handle }
        os_signpost(
            .begin,
            log: log,
            name: Self.signpostName(for: point),
            signpostID: OSSignpostID(handle.id)
        )
        return handle
    }

    package func end(_ handle: TraceHandle) {
        guard log.signpostsEnabled else { return }
        os_signpost(
            .end,
            log: log,
            name: Self.signpostName(for: handle.point),
            signpostID: OSSignpostID(handle.id)
        )
    }

    package func emit(_ point: TracePoint) {
        guard log.signpostsEnabled else { return }
        os_signpost(
            .event,
            log: log,
            name: Self.signpostName(for: point),
            signpostID: OSSignpostID(issueID())
        )
    }

    // MARK: - Private

    private func issueID() -> UInt64 {
        nextID.withLock { current -> UInt64 in
            let issued = current
            current &+= 1
            return issued
        }
    }

    /// The name Instruments labels the track with.
    ///
    /// `os_signpost` takes a `StaticString`, so this cannot be
    /// `point.rawValue`: the name has to be a literal in the binary, which is
    /// what lets the system record a pointer rather than copy a string on a
    /// path that is meant to cost nothing. An exhaustive switch is the price,
    /// and it buys something back — a ``TracePoint`` added without a name here
    /// does not compile.
    private static func signpostName(for point: TracePoint) -> StaticString {
        switch point {
        case .homeLoad: "HomeLoad"
        case .searchIndexBuild: "SearchIndexBuild"
        case .searchScan: "SearchScan"
        }
    }
}
