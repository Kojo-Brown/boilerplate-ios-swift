import Foundation
@testable import Core

/// Reports built by hand, because MetricKit's are not buildable at all.
///
/// Every MetricKit class — `MXDiagnosticPayload`, `MXCrashDiagnostic`,
/// `MXCallStackTree`, `MXMetaData` — has no public initialiser, and the framework
/// delivers payloads once a day, on a device, for the day before. So the seam the
/// whole feature is arranged around is the one these fixtures stand on: everything
/// from `CrashReport` outward is tested, and `MetricKitProjection` is the one file
/// that is not and cannot be here. `docs/crash-reporting.md` says what that
/// leaves unverified.
enum CrashReportFixture {

    /// A fixed instant, so a digest is a constant rather than a function of when
    /// the suite ran.
    static let windowEnd = Date(timeIntervalSince1970: 1_750_000_000)
    static let windowStart = Date(timeIntervalSince1970: 1_749_913_600)

    static let build = BuildIdentity(
        applicationVersion: "1.4.2",
        buildVersion: "2041",
        osVersion: "17.4.1",
        deviceType: "iPhone14,2",
        platformArchitecture: "arm64e",
        isTestFlightBuild: false
    )

    /// A deliberately fake UUID: a real binary UUID in a fixture is the kind of
    /// thing somebody later mistakes for a symbolication target.
    static let binaryUUID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    static func frame(offset: Int, depth: Int = 0, name: String? = "MockApp") -> StackFrame {
        StackFrame(binaryUUID: binaryUUID, offset: offset, binaryName: name, depth: depth)
    }

    static func stack(
        attributed: Bool = true,
        offsets: [Int] = [0x1000, 0x2000],
        truncated: Bool = false
    ) -> CallStack {
        CallStack(
            isAttributed: attributed,
            frames: offsets.enumerated().map { index, offset in
                frame(offset: offset, depth: index)
            },
            isTruncated: truncated
        )
    }

    static func tree(_ stacks: [CallStack] = [stack()], truncated: Bool = false) -> CallStackTree {
        CallStackTree(stacks: stacks, isTruncated: truncated)
    }

    static let signature = CrashSignature(
        exceptionType: 1,
        exceptionCode: 0,
        signal: 11,
        terminationReason: "Namespace SIGNAL, Code 11"
    )

    /// A crash report. Pass `offsets` to make a *different* defect, and
    /// `windowEnd` to make the same defect on a different day.
    static func crash(
        offsets: [Int] = [0x1000, 0x2000],
        windowEnd: Date = CrashReportFixture.windowEnd
    ) -> CrashReport {
        CrashReport(
            windowStart: windowStart,
            windowEnd: windowEnd,
            build: build,
            subject: .crash(signature),
            callStack: tree([stack(offsets: offsets)])
        )
    }

    static func hang(
        seconds: Double = 2.4,
        windowEnd: Date = CrashReportFixture.windowEnd
    ) -> CrashReport {
        CrashReport(
            windowStart: windowStart,
            windowEnd: windowEnd,
            build: build,
            subject: .hang(seconds: seconds),
            callStack: tree()
        )
    }

    /// `count` reports that are all different defects, oldest window first.
    static func series(count: Int) -> [CrashReport] {
        (0..<count).map { index in
            crash(
                offsets: [0x1000 + index],
                windowEnd: windowEnd.addingTimeInterval(Double(index))
            )
        }
    }
}
