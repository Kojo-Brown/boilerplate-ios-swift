import Foundation

// MARK: - Accumulator

/// The three sets an evaluation builds up, with the one invariant that matters
/// attached to the only two operations that can break it: a signal is either
/// fired or marked unassessable, never both and never neither.
private struct Findings {
    var signals: Set<IntegritySignal> = []
    var unavailable: Set<IntegritySignal> = []
    var evidence: [IntegritySignal: [String]] = [:]

    /// Records that `signal` fired, and what fired it.
    ///
    /// `because` is sorted here rather than at the call sites so that two equal
    /// observations cannot produce two unequal reports — `Set` iteration order
    /// is not stable across runs, and a report that is only *sometimes* equal to
    /// itself makes every test flaky in a way that takes a day to find.
    mutating func fire(_ signal: IntegritySignal, because paths: Set<String> = []) {
        signals.insert(signal)
        if !paths.isEmpty {
            evidence[signal] = paths.sorted()
        }
    }

    /// Records that `signal` could not be assessed here. See
    /// `IntegrityReport.unavailableHeuristics` for why this is not a pass.
    mutating func skip(_ signal: IntegritySignal) {
        unavailable.insert(signal)
    }
}

// MARK: - Evaluator

/// Turns one pass of observations into a report, and nothing else.
///
/// This type touches no system API at all — no `FileManager`, no `Bundle`, no
/// `sysctl`, no `dyld`. That is not tidiness, it is the only reason any of this
/// is testable: a jailbroken device cannot be brought into CI, so the half of
/// the work that decides what an observation *means* has to be reachable with a
/// value a test writes down by hand. `SystemIntegrityProbe` is the half that
/// cannot be tested here, and it is deliberately as small and as free of
/// judgement as it could be made.
///
/// `Tools/assert-integrity-heuristics.py` fails if this file ever names a system
/// API, because the first reasonable-looking step away from that split — "just
/// read `Bundle.main` here, it is right there" — is the step that makes the
/// whole evaluation untestable again.
///
/// ## Availability is not a negative
///
/// Every rule below decides two things: whether the signal fired, and whether it
/// could have. The second is what keeps the suite honest. On a simulator the
/// root filesystem is the Mac's, so the artefact list and the writable-path
/// check are meaningless rather than clean; on a development build a debugger is
/// the expected state and an unencrypted binary is the only possible state. A
/// report that called any of those a pass would be reporting a clean bill of
/// health from checks that never ran — which is every run in CI.
package struct DeviceIntegrityEvaluator: Sendable {

    private let baseline: IntegrityBaseline

    package init(baseline: IntegrityBaseline) {
        self.baseline = baseline
    }

    /// Reads `observations` against the baseline this evaluator was built with.
    package func evaluate(_ observations: IntegrityObservations) -> IntegrityReport {
        var findings = Findings()
        assessFilesystem(observations, into: &findings)
        assessThisProcess(observations, into: &findings)
        assessProvenance(observations, into: &findings)

        return IntegrityReport(
            signals: findings.signals,
            unavailableHeuristics: findings.unavailable,
            evidence: findings.evidence,
            baseline: baseline
        )
    }

    // MARK: - Is the sandbox holding?

    /// A simulator's `/` is the host Mac's `/`, where `/bin/sh`, `/usr/bin/ssh`
    /// and `/etc/apt` may all exist and `/private` may well be writable. Both
    /// filesystem heuristics are unassessable there — not negative, and
    /// certainly not positive.
    private func assessFilesystem(_ observations: IntegrityObservations, into findings: inout Findings) {
        guard !observations.runningInSimulator else {
            findings.skip(.jailbreakArtefactOnDisk)
            findings.skip(.filesystemWritableOutsideContainer)
            return
        }
        if !observations.jailbreakArtefacts.isEmpty {
            findings.fire(.jailbreakArtefactOnDisk, because: observations.jailbreakArtefacts)
        }
        if !observations.writablePathsOutsideContainer.isEmpty {
            findings.fire(
                .filesystemWritableOutsideContainer,
                because: observations.writablePathsOutsideContainer
            )
        }
    }

    // MARK: - Is anything in here that should not be?

    /// The injected-library check is the one heuristic assessable everywhere,
    /// including in CI, and the only one that is about this process rather than
    /// about the device: an image list is this process's own, and a framework
    /// hooking this app has to be in it to do the hooking.
    ///
    /// The debugger check is the opposite — running under one is the developer's
    /// own workflow on a development build, and somebody else's on a
    /// distribution build — so it is only assessed on the latter.
    private func assessThisProcess(_ observations: IntegrityObservations, into findings: inout Findings) {
        if !observations.injectedLibraries.isEmpty {
            findings.fire(.injectedLibraryLoaded, because: observations.injectedLibraries)
        }
        guard baseline.channel.isDistribution else {
            findings.skip(.debuggerAttached)
            return
        }
        if observations.debuggerAttached {
            findings.fire(.debuggerAttached)
        }
    }

    // MARK: - Is this the build that was shipped?

    /// The bundle identifier is checked on every channel, because a repackaged
    /// build is a repackaged build however it was distributed. The other two are
    /// statements about what Apple does to a build it distributes, so neither
    /// says anything about a build Apple did not distribute.
    private func assessProvenance(_ observations: IntegrityObservations, into findings: inout Findings) {
        assessBundleIdentifier(observations, into: &findings)

        guard baseline.channel.isDistribution else {
            findings.skip(.provisioningProfileOnAStoreBuild)
            findings.skip(.mainExecutableNotEncrypted)
            return
        }
        if observations.provisioningProfilePresent {
            findings.fire(.provisioningProfileOnAStoreBuild)
        }
        switch observations.mainExecutableEncryption {
        case .notEncrypted:
            findings.fire(.mainExecutableNotEncrypted)
        case .encrypted:
            break
        case .noEncryptionLoadCommand, .unreadable:
            // A distribution build with no encryption load command at all is not
            // a decrypted binary — it is an image this probe could not read as
            // one, and the honest report of that is the same as for a header it
            // could not walk.
            findings.skip(.mainExecutableNotEncrypted)
        }
    }

    /// `nil` is not a mismatch. A process with no main bundle identifier has not
    /// told us a different one, it has told us nothing, and a heuristic that
    /// treats absence as evidence fires on every host that is not an app.
    private func assessBundleIdentifier(
        _ observations: IntegrityObservations,
        into findings: inout Findings
    ) {
        guard let running = observations.bundleIdentifier else {
            findings.skip(.bundleIdentifierMismatch)
            return
        }
        if running != baseline.expectedBundleIdentifier {
            findings.fire(.bundleIdentifierMismatch, because: [running])
        }
    }
}
