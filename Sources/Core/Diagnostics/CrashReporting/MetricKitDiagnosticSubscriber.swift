import Foundation
import MetricKit

// MARK: - Projection

/// Turns MetricKit's objects into ``CrashReport`` values.
///
/// Everything in this type is field copying. That is on purpose and it is the
/// whole reason the rest of this feature is testable: no MetricKit class has a
/// public initialiser, and the framework delivers payloads only on a real device,
/// once a day, for the day before — so any decision taken on this side of the seam
/// is a decision no test in this repository can reach.
///
/// The call stacks are the exception, and only because `MXCallStackTree` is
/// opaque: its entire public surface is `jsonRepresentation() -> Data`, so the
/// frames have to be parsed rather than read. That hands the one piece of real
/// logic here — the frame walk, its bounds, the thread reordering — to
/// ``CallStackTreeParser``, which takes `Data` and is therefore covered by tests.
///
/// What remains untestable here is listed in `docs/crash-reporting.md` and is
/// checked structurally instead, by `Tools/assert-crash-reporting.py`: that this
/// file holds no policy, that it is the only file in the package that imports
/// MetricKit, and that the fields the project deliberately leaves behind stay
/// left behind.
package struct MetricKitProjection: Sendable {

    private let limits: CrashReportLimits

    package init(limits: CrashReportLimits = .standard) {
        self.limits = limits
    }

    /// Every diagnostic in `payload`, in a fixed order: crashes, then hangs, then
    /// the three budget diagnostics.
    ///
    /// Fixed rather than MetricKit's own grouping order, because
    /// ``CrashReportPipeline/accept(_:)`` caps the list and drops from the end. A
    /// cap that dropped whichever section the framework happened to put last
    /// would silently decide that hangs matter less than disk writes on some OS
    /// versions and not others; this says which comes first, once, here.
    package func reports(from payload: MXDiagnosticPayload) -> [CrashReport] {
        let window = (start: payload.timeStampBegin, end: payload.timeStampEnd)
        var reports: [CrashReport] = []

        for crash in payload.crashDiagnostics ?? [] {
            reports.append(report(crash, subject: .crash(signature(of: crash)), window: window))
        }
        for hang in payload.hangDiagnostics ?? [] {
            let seconds = hang.hangDuration.converted(to: .seconds).value
            reports.append(report(hang, subject: .hang(seconds: seconds), window: window))
        }
        for cpu in payload.cpuExceptionDiagnostics ?? [] {
            let subject = DiagnosticSubject.cpuException(
                cpuSeconds: cpu.totalCPUTime.converted(to: .seconds).value,
                sampledSeconds: cpu.totalSampledTime.converted(to: .seconds).value
            )
            reports.append(report(cpu, subject: subject, window: window))
        }
        for write in payload.diskWriteExceptionDiagnostics ?? [] {
            let bytes = write.totalWritesCaused.converted(to: .bytes).value
            let subject = DiagnosticSubject.diskWriteException(bytesWritten: Int(bytes))
            reports.append(report(write, subject: subject, window: window))
        }
        for launch in payload.appLaunchDiagnostics ?? [] {
            let seconds = launch.launchDuration.converted(to: .seconds).value
            reports.append(report(launch, subject: .appLaunch(seconds: seconds), window: window))
        }
        return reports
    }

    // MARK: - One diagnostic

    private func report(
        _ diagnostic: MXDiagnostic,
        subject: DiagnosticSubject,
        window: (start: Date, end: Date)
    ) -> CrashReport {
        CrashReport(
            windowStart: window.start,
            windowEnd: window.end,
            build: identity(of: diagnostic),
            subject: subject,
            callStack: tree(from: diagnostic.callStackTree)
        )
    }

    private func signature(of crash: MXCrashDiagnostic) -> CrashSignature {
        CrashSignature(
            exceptionType: crash.exceptionType?.intValue,
            exceptionCode: crash.exceptionCode?.intValue,
            signal: crash.signal?.intValue,
            terminationReason: limits.truncating(terminationReason: crash.terminationReason)
        )
    }

    /// `MXMetaData.regionFormat` is read by nothing here, deliberately — see
    /// ``BuildIdentity``.
    private func identity(of diagnostic: MXDiagnostic) -> BuildIdentity {
        let metaData = diagnostic.metaData
        return BuildIdentity(
            applicationVersion: diagnostic.applicationVersion,
            buildVersion: metaData.applicationBuildVersion,
            osVersion: metaData.osVersion,
            deviceType: metaData.deviceType,
            platformArchitecture: metaData.platformArchitecture,
            isTestFlightBuild: metaData.isTestFlightApp
        )
    }

    // MARK: - The stacks

    /// Delegated, because `MXCallStackTree` is opaque: no `callStacks` property,
    /// no `MXCallStack`, no `MXFrame` — `jsonRepresentation()` is the whole public
    /// surface. ``CallStackTreeParser`` takes `Data`, which is what makes the frame
    /// walk and every bound on it testable; see that type.
    private func tree(from captured: MXCallStackTree) -> CallStackTree {
        CallStackTreeParser(limits: limits).parse(captured.jsonRepresentation())
    }
}

// MARK: - The subscriber

/// Registers with MetricKit and feeds what it delivers into a
/// ``CrashReportPipeline``.
///
/// ```swift
/// // From the composition root, once, for the life of the process.
/// let reporting = MetricKitDiagnosticSubscriber(pipeline: pipeline)
/// reporting.start()
/// ```
///
/// ## Why it has to be held
///
/// `MXMetricManager.add(_:)` does not retain its subscriber. A subscriber created
/// and dropped in the same expression compiles, registers, and is deallocated
/// before the first payload — which looks exactly like a device that has not
/// crashed. `AppContainer` holds this for the life of the process for the same
/// reason it holds `SessionObserver`.
///
/// ## Why the callback does the write
///
/// `didReceive(_ payloads: [MXDiagnosticPayload])` is the only delivery there
/// will ever be for those payloads. So the body projects and spools
/// synchronously, and only *then* starts a task to upload. Written the other way
/// round — `Task { await pipeline.accept(...) }` — it would compile, pass a test,
/// and lose a payload on any launch the system cut short.
///
/// `nonisolated` on both callbacks because MetricKit promises nothing about which
/// queue it calls on. `MXDiagnosticPayload` is not `Sendable`, which is the
/// compiler stating the same fact: the payload cannot leave this call, so it is
/// projected into values here and the values are what cross.
///
/// ``start()`` and ``stop()`` are `@MainActor` instead, which costs nothing — the
/// only caller is app startup — and settles the question of which isolation
/// `MXMetricManager` wants rather than assuming it wants none.
package final class MetricKitDiagnosticSubscriber: NSObject, MXMetricManagerSubscriber {

    private let pipeline: CrashReportPipeline
    private let projection: MetricKitProjection

    package init(pipeline: CrashReportPipeline, projection: MetricKitProjection = MetricKitProjection()) {
        self.pipeline = pipeline
        self.projection = projection
        super.init()
    }

    /// Subscribes, and drains whatever an earlier launch left behind.
    ///
    /// The drain is here rather than left to the first payload because the two
    /// are independent: a report spooled yesterday and not uploaded — the device
    /// was offline, the server was down — has to go on a launch where MetricKit
    /// delivers nothing at all, which is most launches.
    @MainActor
    package func start() {
        MXMetricManager.shared.add(self)
        // Bound to a local so the task captures the pipeline rather than `self`:
        // this class is not `Sendable` — it is an `NSObject` MetricKit holds a
        // reference to — and the pipeline is an actor, which is.
        let sink = pipeline
        Task { await sink.drain() }
    }

    /// Unsubscribes. Paired with ``start()`` for symmetry and for tests; the app
    /// never calls it, because the subscription's natural lifetime is the process.
    @MainActor
    package func stop() {
        MXMetricManager.shared.remove(self)
    }

    /// Required by `MXMetricManagerSubscriber` and deliberately empty.
    ///
    /// `MXMetricPayload` is the daily *metrics* report — launch times, cellular
    /// conditions, animation hitches — and it is a different feature from this
    /// one, with a different privacy answer: it is histograms of performance
    /// rather than stacks of a failure. Accepting it here to "have the data"
    /// would mean transmitting it, which would mean declaring it, and nothing in
    /// this app reads it. An adopter who wants it has one method to fill in.
    package nonisolated func didReceive(_ payloads: [MXMetricPayload]) {}

    package nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let reports = payloads.flatMap { projection.reports(from: $0) }
        // Synchronous, and before the task below. See the note on the type.
        pipeline.accept(reports)
        let sink = pipeline
        Task { await sink.drain() }
    }
}
