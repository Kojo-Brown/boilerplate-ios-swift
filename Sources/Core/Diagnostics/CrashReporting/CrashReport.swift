import CryptoKit
import Foundation

// MARK: - What a diagnostic is about

/// The five things MetricKit will tell an app about itself after the fact.
///
/// All five are projected even though Phase 11 item 7 asks for crashes and
/// hangs, and that is not scope creep — it is the same durability argument the
/// rest of this file is built on. `MXDiagnosticPayload` carries all five
/// sections in one delivery, that delivery happens once, and a section nobody
/// read is a section nobody will ever get a second chance to read. Handling two
/// and silently discarding three would make the other three *unreportable*
/// rather than merely unreported.
package enum DiagnosticKind: String, Sendable, Codable, CaseIterable {

    /// The process was terminated: a signal, a Mach exception, or a watchdog.
    case crash

    /// The main thread was unresponsive long enough for the system to notice.
    case hang

    /// The app used more CPU than its budget over a sampling window.
    case cpuException

    /// The app wrote more to disk than its budget over a sampling window.
    case diskWriteException

    /// A launch took long enough for the system to consider it a defect.
    case appLaunch
}

/// What the system said killed the process.
///
/// Four optionals, because MetricKit populates them according to *how* the
/// process died and there is no combination that is always present: a `SIGKILL`
/// from the watchdog has a termination reason and no exception code, a
/// `SIGSEGV` has a signal and an exception type and no termination reason. A
/// model that demanded all four would be a model that could not represent a
/// real crash.
package struct CrashSignature: Sendable, Equatable, Codable {

    /// The Mach exception type, e.g. 1 for `EXC_BAD_ACCESS`.
    package let exceptionType: Int?

    /// The Mach exception code.
    package let exceptionCode: Int?

    /// The BSD signal, e.g. 11 for `SIGSEGV`.
    package let signal: Int?

    /// The system's own termination text, truncated to the projection's limit.
    ///
    /// The one free-form string that leaves the device. It is written by the
    /// system rather than by the app or the person using it — `jetsam`'s
    /// pressure note, the watchdog's scene-update deadline — and it is capped
    /// anyway, because "written by the system" is an argument about today's iOS
    /// and the cap is a property of this code.
    package let terminationReason: String?

    package init(
        exceptionType: Int?,
        exceptionCode: Int?,
        signal: Int?,
        terminationReason: String?
    ) {
        self.exceptionType = exceptionType
        self.exceptionCode = exceptionCode
        self.signal = signal
        self.terminationReason = terminationReason
    }

    /// The signature's contribution to a report's digest.
    ///
    /// The termination reason is **excluded**, and that is the one judgement call
    /// in this type. It frequently embeds a number that differs between two
    /// occurrences of the same bug — a memory footprint in a jetsam note, a
    /// deadline in a watchdog note — so including it would give every instance of
    /// one crash a different digest, which is the one thing a digest exists to
    /// stop.
    package var canonicalForm: String {
        let fields = [exceptionType, exceptionCode, signal]
        return fields.map { field in field.map { "\($0)" } ?? "-" }.joined(separator: ",")
    }
}

/// The measurements that come with each kind of diagnostic.
///
/// An enum with associated values rather than a struct of optionals, because the
/// pairing is exact: a hang has a duration and no byte count, a disk-write
/// exception has a byte count and no duration, and a crash has neither. Spelled
/// as a struct, every reader would have to know which fields are populated for
/// which kind, and every writer could populate the wrong ones.
///
/// `Codable` is synthesised. The encoding puts the case name at the top level,
/// so the wire format carries its own discriminator and ``kind`` is derived from
/// it rather than stored beside it — there is no way to encode a report whose
/// kind disagrees with its measurements.
package enum DiagnosticSubject: Sendable, Equatable, Codable {

    case crash(CrashSignature)

    /// How long the main thread was unresponsive.
    case hang(seconds: Double)

    /// CPU time used, and the length of the window it was sampled over. Both,
    /// because the first number means nothing without the second.
    case cpuException(cpuSeconds: Double, sampledSeconds: Double)

    /// Bytes the app caused to be written.
    case diskWriteException(bytesWritten: Int)

    /// How long the launch took.
    case appLaunch(seconds: Double)

    /// Which kind of diagnostic this is.
    package var kind: DiagnosticKind {
        switch self {
        case .crash: .crash
        case .hang: .hang
        case .cpuException: .cpuException
        case .diskWriteException: .diskWriteException
        case .appLaunch: .appLaunch
        }
    }

    /// The subject's contribution to a report's digest.
    ///
    /// Durations are bucketed to whole seconds and byte counts to whole
    /// kilobytes. Two hangs of the same bug last 2.31 and 2.47 seconds; hashing
    /// the raw doubles would make them two different reports, and would make the
    /// digest depend on the floating-point formatting of a `Double`.
    package var canonicalForm: String {
        switch self {
        case .crash(let signature):
            "crash/\(signature.canonicalForm)"
        case .hang(let seconds):
            "hang/\(Int(seconds.rounded(.down)))"
        case .cpuException(let cpuSeconds, let sampledSeconds):
            "cpu/\(Int(cpuSeconds.rounded(.down)))/\(Int(sampledSeconds.rounded(.down)))"
        case .diskWriteException(let bytesWritten):
            "disk/\(bytesWritten / 1024)"
        case .appLaunch(let seconds):
            "launch/\(Int(seconds.rounded(.down)))"
        }
    }
}

// MARK: - Which build this is about

/// Which build of the app, on which OS, the diagnostic came from.
///
/// All of it out of `MXMetaData` and `MXDiagnostic.applicationVersion`, with one
/// field of that metadata deliberately left behind: `regionFormat`. It is the
/// user's region, it narrows who they are, and no crash has ever been fixed by
/// knowing it. The rest is about the binary and the device model, which is what
/// a report has to carry to be actionable at all — a stack offset without the
/// build it was taken from symbolicates against the wrong dSYM.
package struct BuildIdentity: Sendable, Equatable, Codable {

    /// `CFBundleShortVersionString`, e.g. `1.4.2`.
    package let applicationVersion: String

    /// `CFBundleVersion`, e.g. `2041`. The half that identifies the dSYM.
    package let buildVersion: String

    /// e.g. `17.4.1`.
    package let osVersion: String

    /// e.g. `iPhone14,2`.
    package let deviceType: String

    /// e.g. `arm64e`. Needed to pick the right slice when symbolicating.
    package let platformArchitecture: String

    /// Whether this came from a TestFlight install.
    ///
    /// Worth a field of its own because it changes what the report means: a hang
    /// reported by 4 testers is a release blocker, the same hang reported by 4
    /// users of the shipped build is an incident.
    package let isTestFlightBuild: Bool

    package init(
        applicationVersion: String,
        buildVersion: String,
        osVersion: String,
        deviceType: String,
        platformArchitecture: String,
        isTestFlightBuild: Bool
    ) {
        self.applicationVersion = applicationVersion
        self.buildVersion = buildVersion
        self.osVersion = osVersion
        self.deviceType = deviceType
        self.platformArchitecture = platformArchitecture
        self.isTestFlightBuild = isTestFlightBuild
    }

    /// The identity's contribution to a report's digest.
    ///
    /// The OS version is in and the device model is **out**. A bug that only
    /// happens on iOS 18.1 is a different bug from the same stack on 17.4 and
    /// wants its own row; a bug that happens on nine iPhone models is one bug,
    /// and hashing the model would split it into nine.
    package var canonicalForm: String {
        "\(applicationVersion)/\(buildVersion)/\(osVersion)/\(platformArchitecture)"
    }
}

// MARK: - The report

/// One diagnostic, projected out of MetricKit into a value this app can spool,
/// upload, decode and assert on.
///
/// ## Why there is a value type here at all
///
/// Because nothing in `MXDiagnosticPayload` can be constructed. Every MetricKit
/// class has no public initialiser — `MXCrashDiagnostic`, `MXHangDiagnostic`,
/// `MXCallStackTree`, `MXMetaData`, all of them — and the framework delivers
/// payloads only on a real device, once a day, for the previous day. So a
/// pipeline written against MetricKit's own types is a pipeline that cannot be
/// tested anywhere: not in CI, not on a simulator, not on a developer's device
/// inside a reasonable loop.
///
/// Projecting at the edge moves the whole of the logic — the bounds, the
/// durability, the de-duplication, the retry classification, the redaction —
/// onto a type a test can build. What is left on the far side of the seam is one
/// file of field copying, and that file is the only part of this feature that
/// genuinely cannot be exercised here. See ``MetricKitDiagnosticSubscriber``.
///
/// ## What is not in it
///
/// `MXCrashDiagnostic.virtualMemoryRegionInfo` is dropped. It is a textual dump
/// of the process's memory map, it is by far the largest field in a crash
/// diagnostic, and it is useful for one class of bug — a wild pointer whose
/// target region you want named. Spooling it would multiply the size of every
/// report on the chance of needing it on one of them. An adopter who is chasing
/// that bug has one field to add, and `docs/crash-reporting.md` says so.
package struct CrashReport: Sendable, Equatable, Codable {

    /// Wire-format marker, encoded with every report.
    ///
    /// Inside the payload rather than only in a URL or a header, for the same
    /// reason `AttestationClientData` puts its marker in the signed bytes: a
    /// server that learns which shape to parse from somewhere other than the
    /// document it is parsing has two sources of truth for one fact. A spooled
    /// report also outlives the app version that wrote it — it sits on disk
    /// across an update — so the reader of a spool file needs the version too.
    package static let format = "crash-report/1"

    /// Start of the window the payload covered.
    package let windowStart: Date

    /// End of the window the payload covered.
    ///
    /// This is as close to "when it happened" as MetricKit gets.
    /// `MXDiagnosticPayload` timestamps the *payload*, not each diagnostic in it,
    /// so every report out of one delivery shares this value. Anything more
    /// precise would be invented, and a crash report with an invented timestamp
    /// is worse than one with a coarse honest one.
    package let windowEnd: Date

    package let build: BuildIdentity

    /// What happened, and the numbers belonging to it. ``kind`` reads through.
    package let subject: DiagnosticSubject

    package let callStack: CallStackTree

    package init(
        windowStart: Date,
        windowEnd: Date,
        build: BuildIdentity,
        subject: DiagnosticSubject,
        callStack: CallStackTree
    ) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.build = build
        self.subject = subject
        self.callStack = callStack
    }

    /// Which kind of diagnostic this is, read out of ``subject``.
    package var kind: DiagnosticKind { subject.kind }

    /// The exact bytes ``digest`` hashes.
    ///
    /// Spelled out as one string rather than fed field by field into a hasher,
    /// so that `CrashReportTests` can pin the layout as a literal. A test that
    /// rebuilt the layout from the same properties would pass through exactly the
    /// change that makes two builds of this app disagree about what one crash is
    /// called — which is the change that silently splits one row in a server's
    /// crash list into two.
    ///
    /// `windowEnd` is **not** in it. The digest answers "is this the same
    /// defect?", not "is this the same delivery", so two occurrences of one crash
    /// on consecutive days have to agree. Which day a report came from is already
    /// on the report.
    package var canonicalForm: String {
        [
            CrashReport.format,
            kind.rawValue,
            build.canonicalForm,
            subject.canonicalForm,
            callStack.canonicalForm,
        ].joined(separator: "\n")
    }

    /// A stable name for this defect: lowercase hex SHA-256 of ``canonicalForm``.
    ///
    /// It does three jobs, which is why it is derived rather than a `UUID`
    /// minted at projection time.
    ///
    /// * It is the spool's filename, so a payload delivered twice — which
    ///   MetricKit does not promise but has been observed to do after a restore
    ///   — overwrites one file instead of queuing two uploads.
    /// * It is the upload's `Idempotency-Key`, so a request whose response was
    ///   lost is collapsed by the server rather than counted twice.
    /// * It is what a server groups by, so "this crash, 1,400 times" is one row.
    ///
    /// Hex, lowercase, 64 characters: every character is in the unreserved set,
    /// which is what lets it be an `IdempotencyKey` and a filename without
    /// escaping either.
    package var digest: String {
        SHA256.hash(data: Data(canonicalForm.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A one-line summary for a log, carrying no free-form text.
    package var summary: String {
        let seconds = Int(windowEnd.timeIntervalSince1970)
        return "\(kind.rawValue) \(digest.prefix(12)) \(build.buildVersion) w\(seconds)"
    }
}
