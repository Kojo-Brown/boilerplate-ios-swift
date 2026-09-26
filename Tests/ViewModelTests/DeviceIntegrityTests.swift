import Foundation
import Testing
@testable import Core

// MARK: - Fixtures

/// The device states worth a rule, written down rather than owned.
///
/// This is the payoff from splitting the pass into a probe and an evaluator: a
/// rootless jailbreak, a resigned store build and a debugger on a TestFlight
/// install are all values here, and none of them needs a device that CI cannot
/// have. What is *not* here is the case that matters most — a device whose
/// hooking framework answers every one of these probes with a lie — because no
/// arrangement of this test file can produce it and no in-process check can
/// detect it. `docs/threat-model.md` opens with that limit.
enum IntegrityFixture {

    static let storeBaseline = IntegrityBaseline(
        expectedBundleIdentifier: "com.example.fixture",
        channel: .appStore
    )

    static let developmentBaseline = IntegrityBaseline(
        expectedBundleIdentifier: "com.example.fixture",
        channel: .development
    )

    static let testFlightBaseline = IntegrityBaseline(
        expectedBundleIdentifier: "com.example.fixture",
        channel: .testFlight
    )

    /// A store build on a device that looks like the one Apple shipped.
    static let untouchedStoreBuild = IntegrityObservations(
        bundleIdentifier: "com.example.fixture",
        mainExecutableEncryption: .encrypted
    )

    /// The same build, dumped and rebuilt, re-signed, and sideloaded onto a
    /// rootless jailbreak with a tweak loaded into it. Every heuristic at once,
    /// which is the shape of a real cracked install rather than a contrived one.
    static let crackedStoreBuild = IntegrityObservations(
        jailbreakArtefacts: ["/var/jb", "/Applications/Sileo.app"],
        writablePathsOutsideContainer: ["/private"],
        injectedLibraries: ["/var/jb/usr/lib/TweakInject/Shadow.dylib"],
        debuggerAttached: true,
        bundleIdentifier: "com.attacker.repack",
        provisioningProfilePresent: true,
        mainExecutableEncryption: .notEncrypted
    )

    static func evaluate(
        _ observations: IntegrityObservations,
        against baseline: IntegrityBaseline = IntegrityFixture.storeBaseline
    ) -> IntegrityReport {
        DeviceIntegrityEvaluator(baseline: baseline).evaluate(observations)
    }
}

// MARK: - The signals

@Suite("Every heuristic fires on the observation it names, and only on that one")
struct IntegritySignalTests {

    /// The baseline case. A store build that looks untouched raises nothing and,
    /// just as importantly, leaves nothing unassessed — on a real device every
    /// one of these seven heuristics is able to run.
    @Test("An untouched store build fires nothing and skips nothing")
    func untouchedStoreBuildIsQuiet() {
        let report = IntegrityFixture.evaluate(IntegrityFixture.untouchedStoreBuild)
        #expect(report.signals.isEmpty)
        #expect(report.unavailableHeuristics.isEmpty)
        #expect(report.posture == .noSignals)
    }

    /// The other end. A cracked install fires all seven, which is what makes the
    /// seven a suite rather than one check with six spare parts.
    @Test("A cracked, sideloaded install on a jailbroken device fires every signal")
    func crackedInstallFiresEverything() {
        let report = IntegrityFixture.evaluate(IntegrityFixture.crackedStoreBuild)
        #expect(report.signals == Set(IntegritySignal.allCases))
        #expect(report.unavailableHeuristics.isEmpty)
        #expect(report.posture == .strongSignals)
    }

    @Test("A readable jailbreak artefact fires, and carries the paths that fired it")
    func artefactsFireAndCarryEvidence() {
        var observations = IntegrityFixture.untouchedStoreBuild
        observations.jailbreakArtefacts = ["/var/jb", "/etc/apt"]
        let report = IntegrityFixture.evaluate(observations)

        #expect(report.signals == [.jailbreakArtefactOnDisk])
        #expect(report.evidence[.jailbreakArtefactOnDisk] == ["/etc/apt", "/var/jb"])
    }

    @Test("A writable path outside the container fires, and carries it")
    func writablePathFires() {
        var observations = IntegrityFixture.untouchedStoreBuild
        observations.writablePathsOutsideContainer = ["/private", "/"]
        let report = IntegrityFixture.evaluate(observations)

        #expect(report.signals == [.filesystemWritableOutsideContainer])
        #expect(report.evidence[.filesystemWritableOutsideContainer] == ["/", "/private"])
    }

    @Test("An injected library fires, and carries the image path")
    func injectedLibraryFires() {
        var observations = IntegrityFixture.untouchedStoreBuild
        observations.injectedLibraries = ["/usr/lib/libhooker.dylib"]
        let report = IntegrityFixture.evaluate(observations)

        #expect(report.signals == [.injectedLibraryLoaded])
        #expect(report.evidence[.injectedLibraryLoaded] == ["/usr/lib/libhooker.dylib"])
    }

    @Test("A bundle identifier that is not the declared one fires, and names what it found")
    func bundleMismatchFires() {
        var observations = IntegrityFixture.untouchedStoreBuild
        observations.bundleIdentifier = "com.attacker.repack"
        let report = IntegrityFixture.evaluate(observations)

        #expect(report.signals == [.bundleIdentifierMismatch])
        #expect(report.evidence[.bundleIdentifierMismatch] == ["com.attacker.repack"])
    }

    @Test("A provisioning profile on a store build fires")
    func provisioningProfileFires() {
        var observations = IntegrityFixture.untouchedStoreBuild
        observations.provisioningProfilePresent = true
        let report = IntegrityFixture.evaluate(observations)

        #expect(report.signals == [.provisioningProfileOnAStoreBuild])
        #expect(report.posture == .moderateSignals)
    }

    @Test("A store build whose main executable is not encrypted fires")
    func decryptedBinaryFires() {
        var observations = IntegrityFixture.untouchedStoreBuild
        observations.mainExecutableEncryption = .notEncrypted
        let report = IntegrityFixture.evaluate(observations)

        #expect(report.signals == [.mainExecutableNotEncrypted])
        #expect(report.posture == .strongSignals)
    }

    @Test("A debugger on a distribution build fires", arguments: [
        IntegrityFixture.storeBaseline,
        IntegrityFixture.testFlightBaseline,
    ])
    func debuggerFiresOnDistributionBuilds(baseline: IntegrityBaseline) {
        var observations = IntegrityFixture.untouchedStoreBuild
        observations.debuggerAttached = true
        let report = IntegrityFixture.evaluate(observations, against: baseline)

        #expect(report.signals == [.debuggerAttached])
        #expect(report.posture == .moderateSignals)
    }

    /// The rule that makes the whole thing worth shipping in an app rather than
    /// in a document: every signal reachable from `IntegritySignal.allCases` is
    /// reachable from an observation too. A case nothing can raise is a heuristic
    /// that does not exist, and it is a one-line refactor away at all times.
    @Test("Every case of IntegritySignal is raised by some observation")
    func everySignalIsReachable() {
        let report = IntegrityFixture.evaluate(IntegrityFixture.crackedStoreBuild)
        for signal in IntegritySignal.allCases {
            #expect(report.signals.contains(signal), "\(signal.rawValue) is unreachable")
        }
    }
}

// MARK: - What could not be checked

@Suite("A heuristic that could not run reports as unassessed, never as a pass")
struct IntegrityAvailabilityTests {

    /// The one that keeps CI honest. Every run in CI is a simulator run, the
    /// simulator's root filesystem is the Mac's, and `/etc/apt` on a developer's
    /// laptop is a Homebrew artefact rather than a jailbreak — so the two
    /// filesystem heuristics report nothing at all rather than reporting a pass
    /// they did not earn.
    @Test("On a simulator the filesystem heuristics are unassessable, not clean")
    func simulatorSuppressesFilesystemHeuristics() {
        var observations = IntegrityFixture.untouchedStoreBuild
        observations.runningInSimulator = true
        observations.jailbreakArtefacts = ["/etc/apt", "/usr/sbin/sshd"]
        observations.writablePathsOutsideContainer = ["/private"]
        let report = IntegrityFixture.evaluate(observations)

        #expect(report.signals.isEmpty)
        #expect(report.unavailableHeuristics == [
            .jailbreakArtefactOnDisk,
            .filesystemWritableOutsideContainer,
        ])
        #expect(report.posture == .noSignals)
    }

    /// A development build is under a debugger, unencrypted and carrying a
    /// provisioning profile as its *normal* state, so all three of those rules
    /// are meaningless there. Reporting them as passes would put three
    /// permanently green checks in front of every developer, which is how a suite
    /// of heuristics becomes decoration.
    @Test("On a development build the three distribution-only heuristics are unassessable")
    func developmentBuildSuppressesDistributionHeuristics() {
        var observations = IntegrityFixture.untouchedStoreBuild
        observations.debuggerAttached = true
        observations.provisioningProfilePresent = true
        observations.mainExecutableEncryption = .noEncryptionLoadCommand
        let report = IntegrityFixture.evaluate(
            observations,
            against: IntegrityFixture.developmentBaseline
        )

        #expect(report.signals.isEmpty)
        #expect(report.unavailableHeuristics == [
            .debuggerAttached,
            .provisioningProfileOnAStoreBuild,
            .mainExecutableNotEncrypted,
        ])
    }

    /// A missing bundle identifier is not a different bundle identifier. The
    /// distinction is not academic: it is the difference between "this is a
    /// repackaged app" and "this is not an app", and a unit-test process is the
    /// second one.
    @Test("No bundle identifier at all is unassessable, not a mismatch")
    func absentBundleIdentifierIsNotAMismatch() {
        var observations = IntegrityFixture.untouchedStoreBuild
        observations.bundleIdentifier = nil
        let report = IntegrityFixture.evaluate(observations)

        #expect(report.signals.isEmpty)
        #expect(report.unavailableHeuristics == [.bundleIdentifierMismatch])
    }

    /// `MachOEncryptionState` has four cases so that "I could not tell" is not
    /// spelled the same way as "it is not encrypted". These are the two that mean
    /// the first thing.
    @Test(
        "An unreadable or absent encryption load command is unassessable",
        arguments: [MachOEncryptionState.noEncryptionLoadCommand, .unreadable]
    )
    func unreadableEncryptionIsUnassessable(state: MachOEncryptionState) {
        var observations = IntegrityFixture.untouchedStoreBuild
        observations.mainExecutableEncryption = state
        let report = IntegrityFixture.evaluate(observations)

        #expect(report.signals.isEmpty)
        #expect(report.unavailableHeuristics == [.mainExecutableNotEncrypted])
    }

    /// Belt and braces on the invariant `Findings` exists to hold: a signal is
    /// fired or unassessed, never both, whatever the observations say.
    @Test("No signal is ever both fired and unassessable")
    func firedAndUnassessableNeverOverlap() {
        let observations: [IntegrityObservations] = [
            IntegrityFixture.untouchedStoreBuild,
            IntegrityFixture.crackedStoreBuild,
            IntegrityObservations(),
        ]
        let baselines = [
            IntegrityFixture.storeBaseline,
            IntegrityFixture.developmentBaseline,
            IntegrityFixture.testFlightBaseline,
        ]
        for observation in observations {
            for baseline in baselines {
                let report = IntegrityFixture.evaluate(observation, against: baseline)
                #expect(report.signals.isDisjoint(with: report.unavailableHeuristics))
            }
        }
    }
}

// MARK: - Posture and reporting

@Suite("The posture is the strongest thing any fired signal supports")
struct IntegrityPostureTests {

    @Test("Moderate signals alone never read as strong")
    func moderateStaysModerate() {
        var observations = IntegrityFixture.untouchedStoreBuild
        observations.debuggerAttached = true
        observations.provisioningProfilePresent = true
        let report = IntegrityFixture.evaluate(observations)

        #expect(report.signals == [.debuggerAttached, .provisioningProfileOnAStoreBuild])
        #expect(report.posture == .moderateSignals)
    }

    /// One strong signal outranks any number of moderate ones, which is the
    /// property a weighted score would destroy — four moderate observations are
    /// still four things with innocent explanations.
    @Test("One strong signal outranks any number of moderate ones")
    func oneStrongOutranksManyModerate() {
        var observations = IntegrityFixture.untouchedStoreBuild
        observations.debuggerAttached = true
        observations.provisioningProfilePresent = true
        observations.injectedLibraries = ["/usr/lib/libhooker.dylib"]
        let report = IntegrityFixture.evaluate(observations)

        #expect(report.posture == .strongSignals)
    }

    /// The split the threat model turns on: a compromised device is usually the
    /// user's own doing, and a modified build is not something anybody does by
    /// accident. A report that could only say "seven signals" could not tell a
    /// triage queue which of those two it was looking at.
    @Test("A report separates what it saw about the device from what it saw about the build")
    func reportSeparatesDeviceFromBuild() {
        let report = IntegrityFixture.evaluate(IntegrityFixture.crackedStoreBuild)

        #expect(report.signals(in: .jailbreak) == [
            .filesystemWritableOutsideContainer,
            .jailbreakArtefactOnDisk,
        ])
        #expect(report.signals(in: .instrumentation) == [.debuggerAttached])
        #expect(report.signals(in: .tamper).count == 4)
        #expect(report.signals(in: .tamper).contains(.mainExecutableNotEncrypted))
    }

    /// Every category is reachable, and every signal belongs to exactly one.
    /// A category no signal carries is a distinction the vocabulary claims to
    /// make and cannot.
    @Test("Every category has at least one signal, and the categories partition them")
    func categoriesPartitionTheSignals() {
        let report = IntegrityFixture.evaluate(IntegrityFixture.crackedStoreBuild)
        var counted = 0
        for category in IntegrityCategory.allCases {
            let inCategory = report.signals(in: category)
            #expect(!inCategory.isEmpty, "\(category.rawValue) carries no signal")
            counted += inCategory.count
        }
        #expect(counted == IntegritySignal.allCases.count)
    }

    @Test("Postures order from quietest to loudest")
    func posturesOrder() {
        #expect(IntegrityPosture.noSignals < .moderateSignals)
        #expect(IntegrityPosture.moderateSignals < .strongSignals)
    }

    /// Two equal observations must produce two equal reports, or every assertion
    /// above is intermittent: `Set` iteration order is not stable across runs, so
    /// evidence that was not sorted somewhere would make a report only sometimes
    /// equal to itself.
    @Test("Two passes over the same observations produce the same report")
    func evaluationIsDeterministic() {
        let first = IntegrityFixture.evaluate(IntegrityFixture.crackedStoreBuild)
        let second = IntegrityFixture.evaluate(IntegrityFixture.crackedStoreBuild)

        #expect(first == second)
        #expect(first.digest == second.digest)
        #expect(first.firedInOrder == second.firedInOrder)
    }

    /// The digest names the unassessed heuristics as well as the fired ones. A
    /// log line that omitted them would read as a clean run to whoever finds it
    /// six months later, which is the only audience it has.
    @Test("The digest names the channel, the posture, the fired and the unassessed")
    func digestNamesEverything() {
        var observations = IntegrityFixture.untouchedStoreBuild
        observations.runningInSimulator = true
        observations.injectedLibraries = ["/usr/lib/libhooker.dylib"]
        let digest = IntegrityFixture.evaluate(observations).digest

        #expect(digest.contains("channel=appStore"))
        #expect(digest.contains("posture=strong-signals"))
        #expect(digest.contains("fired=injected_library_loaded"))
        #expect(digest.contains("unavailable=filesystem_writable_outside_container"))
        #expect(digest.contains("jailbreak_artefact_on_disk"))
    }

    @Test("A quiet report says so on both halves rather than going silent")
    func quietDigestStillNamesBothHalves() {
        let digest = IntegrityFixture.evaluate(IntegrityFixture.untouchedStoreBuild).digest

        #expect(digest.contains("fired=none"))
        #expect(digest.contains("unavailable=none"))
    }

    @Test("The reporter records the report it was handed")
    func reporterRecordsTheReport() {
        let reporter = RecordingIntegrityReporter()
        let report = IntegrityFixture.evaluate(IntegrityFixture.crackedStoreBuild)

        reporter.report(.evaluated(report))
        reporter.report(.withheldBiometricUnlockRecord(posture: report.posture))

        #expect(reporter.reports == [report])
        #expect(reporter.events.count == 2)
        #expect(reporter.events.last == .withheldBiometricUnlockRecord(posture: .strongSignals))
    }
}
