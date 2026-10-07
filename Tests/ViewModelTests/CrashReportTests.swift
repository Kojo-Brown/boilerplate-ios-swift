import Foundation
import Testing
@testable import Core
@testable import Networking

// MARK: - The digest

@Suite("A report's digest names the defect and not the delivery")
struct CrashReportDigestTests {

    /// The layout is pinned as a literal on purpose.
    ///
    /// A test that rebuilt the canonical form out of the same properties would
    /// pass through exactly the change this is here to catch: a reordering or a
    /// new field, which makes two builds of the app disagree about what one crash
    /// is called and so splits one row in a server's crash list into two for
    /// everybody who updates.
    @Test("The canonical form is the layout a server was told to expect")
    func canonicalFormIsPinned() {
        let report = CrashReportFixture.crash(offsets: [0x1000])
        let expected = [
            "crash-report/1",
            "crash",
            "1.4.2/2041/17.4.1/arm64e",
            "crash/1,0,11",
            "full/attributed/full/0:00000000-0000-4000-8000-000000000001:4096",
        ].joined(separator: "\n")

        #expect(report.canonicalForm == expected)
    }

    @Test("The digest is 64 lowercase hex characters")
    func digestIsHex() {
        let digest = CrashReportFixture.crash().digest
        #expect(digest.count == 64)
        #expect(digest.allSatisfy { "0123456789abcdef".contains($0) })
    }

    /// The property that makes the digest an idempotency key: every character is
    /// in the unreserved set, so it survives a header and a filename untouched.
    @Test("The digest is a usable idempotency key")
    func digestIsAValidIdempotencyKey() {
        #expect(IdempotencyKey(rawValue: CrashReportFixture.crash().digest) != nil)
    }

    @Test("The same defect on two different days has one digest")
    func windowDoesNotChangeTheDigest() {
        let today = CrashReportFixture.crash()
        let tomorrow = CrashReportFixture.crash(
            windowEnd: CrashReportFixture.windowEnd.addingTimeInterval(86_400)
        )
        #expect(today.digest == tomorrow.digest)
        #expect(today != tomorrow)
    }

    @Test("A different stack is a different defect")
    func stackChangesTheDigest() {
        let here = CrashReportFixture.crash(offsets: [0x1000]).digest
        let there = CrashReportFixture.crash(offsets: [0x2000]).digest
        #expect(here != there)
    }

    /// Hang durations are bucketed to whole seconds, so two occurrences of one
    /// stuck main thread group together instead of becoming two defects — and so
    /// that the digest does not depend on how a `Double` happens to print.
    @Test("Hangs within the same second are one defect, across it are two")
    func hangDurationIsBucketed() {
        let low = CrashReportFixture.hang(seconds: 2.1).digest
        let high = CrashReportFixture.hang(seconds: 2.9).digest
        let over = CrashReportFixture.hang(seconds: 3.0).digest
        #expect(low == high)
        #expect(high != over)
    }

    /// The termination reason is excluded from the digest because it embeds
    /// numbers that differ between occurrences of one bug — a footprint in a
    /// jetsam note, a deadline in a watchdog note.
    @Test("The termination reason does not split one crash into many")
    func terminationReasonIsNotInTheDigest() {
        let base = CrashReportFixture.crash()
        let other = CrashReport(
            windowStart: base.windowStart,
            windowEnd: base.windowEnd,
            build: base.build,
            subject: .crash(
                CrashSignature(
                    exceptionType: 1,
                    exceptionCode: 0,
                    signal: 11,
                    terminationReason: "Namespace JETSAM, per-process-limit 1430 MB"
                )
            ),
            callStack: base.callStack
        )
        #expect(base.digest == other.digest)
    }

    /// The device model is out of the digest and the OS version is in it: one bug
    /// across nine iPhone models is one row, the same stack on two iOS majors is
    /// two.
    @Test("The device model does not split a defect; the OS version does")
    func osVersionSplitsAndDeviceModelDoesNot() {
        let base = CrashReportFixture.crash()
        #expect(reportOn(base, deviceType: "iPhone17,1").digest == base.digest)
        #expect(reportOn(base, osVersion: "18.0").digest != base.digest)
    }

    private func reportOn(
        _ report: CrashReport,
        osVersion: String = CrashReportFixture.build.osVersion,
        deviceType: String = CrashReportFixture.build.deviceType
    ) -> CrashReport {
        CrashReport(
            windowStart: report.windowStart,
            windowEnd: report.windowEnd,
            build: BuildIdentity(
                applicationVersion: report.build.applicationVersion,
                buildVersion: report.build.buildVersion,
                osVersion: osVersion,
                deviceType: deviceType,
                platformArchitecture: report.build.platformArchitecture,
                isTestFlightBuild: report.build.isTestFlightBuild
            ),
            subject: report.subject,
            callStack: report.callStack
        )
    }
}

// MARK: - The wire format

@Suite("A report survives the round trip it is spooled and sent through")
struct CrashReportCodingTests {

    @Test("Every kind round-trips through JSON unchanged", arguments: CrashReportTestCase.allSubjects)
    func roundTripsThroughJSON(subject: DiagnosticSubject) throws {
        let report = CrashReport(
            windowStart: CrashReportFixture.windowStart,
            windowEnd: CrashReportFixture.windowEnd,
            build: CrashReportFixture.build,
            subject: subject,
            callStack: CrashReportFixture.tree()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let encoded = try encoder.encode(report)
        let decoded = try decoder.decode(CrashReport.self, from: encoded)
        #expect(decoded == report)
        #expect(decoded.digest == report.digest)
    }

    /// `kind` is derived from `subject` rather than stored beside it, which is
    /// what makes a report whose kind disagrees with its measurements
    /// unrepresentable — and the reason there is no test for that disagreement.
    @Test("The kind reads through from the subject", arguments: CrashReportTestCase.allSubjects)
    func kindFollowsTheSubject(subject: DiagnosticSubject) {
        let report = CrashReport(
            windowStart: CrashReportFixture.windowStart,
            windowEnd: CrashReportFixture.windowEnd,
            build: CrashReportFixture.build,
            subject: subject,
            callStack: .empty
        )
        #expect(report.kind == subject.kind)
    }

    @Test("Every DiagnosticKind has a subject that produces it")
    func everyKindIsReachable() {
        let produced = Set(CrashReportTestCase.allSubjects.map(\.kind))
        #expect(produced == Set(DiagnosticKind.allCases))
    }

    /// The summary goes into a log line, so it must not carry the one free-form
    /// string in the report.
    @Test("The summary carries no termination text")
    func summaryIsFreeOfProse() {
        let summary = CrashReportFixture.crash().summary
        #expect(!summary.contains("Namespace"))
        #expect(summary.contains("crash"))
    }
}

/// The five subjects, in one place, so a new `DiagnosticKind` fails
/// `everyKindIsReachable` rather than quietly going untested.
enum CrashReportTestCase {
    static let allSubjects: [DiagnosticSubject] = [
        .crash(CrashReportFixture.signature),
        .hang(seconds: 2.4),
        .cpuException(cpuSeconds: 42.5, sampledSeconds: 900),
        .diskWriteException(bytesWritten: 1_048_576),
        .appLaunch(seconds: 9.1),
    ]
}

// MARK: - The stacks

@Suite("A call stack tree reports what it blames and what it dropped")
struct CallStackTreeTests {

    @Test("The attributed thread is the blamed one, wherever it sits")
    func blamedFramesComeFromTheAttributedThread() {
        let tree = CrashReportFixture.tree([
            CrashReportFixture.stack(attributed: false, offsets: [0x10]),
            CrashReportFixture.stack(attributed: true, offsets: [0x20]),
        ])
        #expect(tree.blamedFrames.map(\.offset) == [0x20])
    }

    /// A disk-write exception has no guilty thread, so falling back is right and
    /// returning nothing would be a report that reads as empty.
    @Test("With nothing attributed, the first thread is blamed")
    func blamedFramesFallBackToTheFirstThread() {
        let tree = CrashReportFixture.tree([
            CrashReportFixture.stack(attributed: false, offsets: [0x10]),
            CrashReportFixture.stack(attributed: false, offsets: [0x20]),
        ])
        #expect(tree.blamedFrames.map(\.offset) == [0x10])
    }

    @Test("An empty tree blames nothing rather than trapping")
    func emptyTreeBlamesNothing() {
        #expect(CallStackTree.empty.blamedFrames.isEmpty)
    }

    /// Truncation has to be carried rather than inferred: a stack cut at the limit
    /// and a stack that is genuinely that short are indistinguishable once the
    /// frames are counted, and the difference decides whether the bottom of the
    /// stack is missing or absent.
    @Test("Truncation changes the digest, so a cut stack is not the full one")
    func truncationIsPartOfIdentity() {
        let whole = CrashReportFixture.stack(truncated: false)
        let cut = CrashReportFixture.stack(truncated: true)
        #expect(whole.canonicalForm != cut.canonicalForm)
    }

    /// The binary name is excluded from a frame's identity because MetricKit
    /// reports it as `nil` for some frames in some payloads — so including it
    /// would make the digest depend on how much the framework happened to know.
    @Test("A missing binary name does not change a frame's identity")
    func binaryNameIsNotPartOfIdentity() {
        let named = CrashReportFixture.frame(offset: 0x10, name: "MockApp")
        let unnamed = CrashReportFixture.frame(offset: 0x10, name: nil)
        #expect(named.canonicalForm == unnamed.canonicalForm)
        #expect(named != unnamed)
    }

    @Test("Depth is part of a frame's identity")
    func depthIsPartOfIdentity() {
        let root = CrashReportFixture.frame(offset: 0x10, depth: 0)
        let nested = CrashReportFixture.frame(offset: 0x10, depth: 1)
        #expect(root.canonicalForm != nested.canonicalForm)
    }
}

// MARK: - The bounds

@Suite("The projection limits are bounds, not suggestions")
struct CrashReportLimitsTests {

    @Test("The shipped limits are all positive")
    func standardLimitsAreUsable() {
        let limits = CrashReportLimits.standard
        #expect(limits.maxReportsPerPayload > 0)
        #expect(limits.maxStacksPerReport > 0)
        #expect(limits.maxFramesPerStack > 0)
        #expect(limits.maxFrameDepth > 0)
        #expect(limits.spoolCapacity > 0)
    }

    /// The cap on the one free-form string that leaves the device lives on this
    /// type, and not in the projection, precisely so that it can be asserted: the
    /// way such a cap breaks is a comparison against the wrong number, and that
    /// still mentions the limit so it still satisfies any syntactic audit.
    @Test("A termination reason longer than the limit is cut to it")
    func terminationReasonIsCapped() {
        let limits = CrashReportLimits(maxTerminationReasonLength: 8)
        #expect(limits.truncating(terminationReason: "0123456789") == "01234567")
        #expect(limits.truncating(terminationReason: "short") == "short")
    }

    /// `""` and "the system said nothing" are the same fact, so a report spells it
    /// one way.
    @Test("An empty or absent termination reason becomes nil")
    func emptyTerminationReasonBecomesNil() {
        let limits = CrashReportLimits.standard
        #expect(limits.truncating(terminationReason: "") == nil)
        #expect(limits.truncating(terminationReason: nil) == nil)
    }
}
