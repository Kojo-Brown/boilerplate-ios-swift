import Foundation
import SwiftData
import Testing
@testable import BoilerplateiOSSwift
@testable import Core

// The fixtures live in `DeviceIntegrityTests.swift`, which is the other half of
// this file: the two were split when the combined one crossed SwiftLint's
// file-length ceiling, not because they are about different things. This half is
// what the app *does* about a report; that half is how a report is arrived at.

// MARK: - What the app does about it

@Suite("The policy degrades and never refuses to run")
struct IntegrityPolicyTests {

    @Test("Observe changes nothing, whatever fired")
    func observeChangesNothing() {
        let policy = IntegrityPolicy.observe
        let loud = IntegrityFixture.evaluate(IntegrityFixture.crackedStoreBuild)

        #expect(policy.mitigations(for: loud) == .unchanged)
        #expect(!policy.mitigations(for: loud).withholdsBiometricUnlockRecord)
    }

    @Test("The shipped policy withholds the unlock record on strong signals only")
    func shippedPolicyWithholdsOnStrongSignalsOnly() {
        let policy = IntegrityPolicy.restrictOnStrongSignals

        var moderate = IntegrityFixture.untouchedStoreBuild
        moderate.debuggerAttached = true

        var strong = IntegrityFixture.untouchedStoreBuild
        strong.injectedLibraries = ["/usr/lib/libhooker.dylib"]

        let quiet = policy.mitigations(for: IntegrityFixture.evaluate(
            IntegrityFixture.untouchedStoreBuild
        ))
        let onModerate = policy.mitigations(for: IntegrityFixture.evaluate(moderate))
        let onStrong = policy.mitigations(for: IntegrityFixture.evaluate(strong))

        #expect(!quiet.withholdsBiometricUnlockRecord)
        #expect(!onModerate.withholdsBiometricUnlockRecord)
        #expect(onStrong.withholdsBiometricUnlockRecord)
    }

    /// The threshold is a parameter, so a team that has measured its own
    /// false-positive rate can lower it without touching the heuristics.
    @Test("A policy set to restrict at moderate does so")
    func moderateThresholdRestrictsAtModerate() {
        let policy = IntegrityPolicy(response: .restrict(atOrAbove: .moderateSignals))
        var moderate = IntegrityFixture.untouchedStoreBuild
        moderate.debuggerAttached = true

        let onModerate = policy.mitigations(for: IntegrityFixture.evaluate(moderate))
        let quiet = policy.mitigations(for: IntegrityFixture.evaluate(
            IntegrityFixture.untouchedStoreBuild
        ))

        #expect(onModerate.withholdsBiometricUnlockRecord)
        #expect(!quiet.withholdsBiometricUnlockRecord)
    }

    /// The mitigation is *withholding a second copy of a credential* and nothing
    /// else, so there is exactly one field here. The test exists to make adding a
    /// second one a deliberate act: the moment this type grows a
    /// `blocksLaunch`, the argument in `IntegrityResponse` has been lost.
    @Test("The only mitigation available is withholding the unlock record")
    func theOnlyMitigationIsWithholding() {
        let labels = Mirror(reflecting: IntegrityMitigations.unchanged).children.compactMap(\.label)
        #expect(labels == ["withholdsBiometricUnlockRecord"])
    }
}

// MARK: - The real probe

@Suite("The system probe reports what this environment actually is")
struct SystemIntegrityProbeTests {

    /// Most of this type cannot be tested here — a jailbroken device is not
    /// available to CI and never will be — so what is asserted is the part that
    /// is true of the process running the test: the compile-time facts, and that
    /// nothing has hooked the test bundle.
    @Test("The probe agrees with the compile-time environment")
    func probeAgreesWithTheBuild() {
        let observations = SystemIntegrityProbe().observe()

        #expect(observations.runningInSimulator == SystemIntegrityProbe.isSimulator)
        #expect(observations.injectedLibraries.isEmpty)
    }

    /// The main executable of a unit-test process is `xctest`, which is a
    /// well-formed 64-bit Mach-O with nothing FairPlay about it. What matters is
    /// that the walk returns one of the two "could not tell" answers rather than
    /// `.notEncrypted`, because `.notEncrypted` is a signal and this is not one.
    @Test("The Mach-O walk does not mistake an unencrypted test host for a crack")
    func machOWalkDoesNotFireOnTheTestHost() {
        let state = SystemIntegrityProbe.mainExecutableEncryption()
        #expect(state != .encrypted)
        #expect(state != .notEncrypted)
    }

    /// The lists are the heuristics. An empty one is a check that cannot fire,
    /// and the rootless entry is the one most published implementations still
    /// lack — a list that only knows about `/Applications/Cydia.app` has not been
    /// updated since 2019.
    @Test("The artefact list covers the rootless layout and names no Mac path")
    func artefactListIsCurrent() {
        let paths = SystemIntegrityProbe.artefactPaths

        #expect(paths.contains("/var/jb"))
        #expect(paths.contains("/Library/MobileSubstrate/MobileSubstrate.dylib"))
        #expect(!paths.contains("/bin/sh"))
        #expect(!paths.contains("/bin/bash"))
        #expect(Set(paths).count == paths.count)
    }

    @Test("Every escape path is absolute and outside any app container")
    func escapePathsAreOutsideTheContainer() {
        for path in SystemIntegrityProbe.containerEscapePaths {
            #expect(path.hasPrefix("/"))
            #expect(!path.contains("/Containers/"))
        }
    }

    /// Markers are matched against a lowercased image path, so an upper-case
    /// marker can never match anything. The bare word "substitute" is excluded
    /// for the opposite reason: it would one day match a framework path that has
    /// nothing to do with code injection, and a false positive on this signal is
    /// the one that withholds a credential.
    @Test("Injection markers are lowercase and none is an ordinary word")
    func injectionMarkersAreMatchable() {
        let markers = SystemIntegrityProbe.injectionMarkers

        #expect(!markers.isEmpty)
        #expect(markers.allSatisfy { $0 == $0.lowercased() })
        #expect(!markers.contains("substitute"))
        #expect(markers.contains("libhooker"))
    }

    /// The stub is what makes every suite above possible, so it has to hand back
    /// exactly what it was given.
    @Test("The stub probe reports what it was handed")
    func stubProbeIsFaithful() {
        let observations = IntegrityFixture.crackedStoreBuild
        #expect(StubIntegrityProbe(observations).observe() == observations)
        #expect(StubIntegrityProbe().observe() == IntegrityObservations())
    }
}

// MARK: - The composition root

@Suite("The container evaluates integrity once and carries the answer")
@MainActor
struct AppContainerIntegrityTests {

    /// The report is a launch-time value, so the container is the only place it
    /// can be evaluated once. This pins that `live()` carries the report it was
    /// given rather than re-running the heuristics somewhere deeper.
    @Test("live() stores the report it was handed")
    func liveCarriesTheReport() throws {
        let store = try makeInMemoryUserStore()
        let report = IntegrityFixture.evaluate(IntegrityFixture.crackedStoreBuild)
        let container = AppContainer.live(userStore: store, integrity: report)

        #expect(container.integrity == report)
        #expect(container.integrity.posture == .strongSignals)
    }

    private func makeInMemoryUserStore() throws -> any UserPersistenceService {
        let modelContainer = try PersistenceController.makeInMemoryContainer()
        return SwiftDataUserPersistenceService(context: modelContainer.mainContext)
    }

    @Test("The preview graph's probe observes nothing, like every other double")
    func previewIntegrityIsQuiet() {
        #expect(AppContainer.preview.integrity.posture == .noSignals)
    }

    /// The shipped baseline is a literal, and this is the assertion that keeps it
    /// one: if somebody replaces it with `Bundle.main.bundleIdentifier` the
    /// comparison becomes a value against itself, which is a check that can never
    /// fail and is the shape most shipped anti-repackaging code takes.
    @Test("The shipped baseline names a literal bundle identifier")
    func shippedBaselineIsALiteral() {
        let baseline = AppContainer.defaultIntegrityBaseline

        #expect(baseline.expectedBundleIdentifier == AppContainer.expectedBundleIdentifier)
        #expect(baseline.expectedBundleIdentifier != Bundle.main.bundleIdentifier)
        #expect(baseline.channel == AppContainer.buildChannel)
    }

    /// The consequence of that literal, stated rather than hidden: in a test
    /// process `Bundle.main` is the test runner, so the app's own baseline
    /// observes a mismatch and is right to. This is the same fact
    /// `AppContainer.logSubsystem` exists for, and a test that asserted the
    /// opposite would only be asserting that the check had been defeated.
    @Test("Assessed against the real probe, a test process is never the app")
    func theTestProcessIsNotTheApp() {
        let observations = SystemIntegrityProbe().observe()
        let report = AppContainer.assessedIntegrity()

        // Whatever hosts a test bundle, it is not the app, so the identifier
        // heuristic must not come back as a match. Which of the two honest
        // answers it gives depends on whether that host carries an identifier at
        // all, which is xcodebuild's business rather than this package's — and
        // "no identifier" is unassessable, not a pass.
        if observations.bundleIdentifier == nil {
            #expect(report.unavailableHeuristics.contains(.bundleIdentifierMismatch))
        } else {
            #expect(report.signals.contains(.bundleIdentifierMismatch))
        }
        #expect(report.baseline.channel == AppContainer.buildChannel)
        if AppContainer.buildChannel == .development {
            #expect(report.unavailableHeuristics.contains(.debuggerAttached))
        }
    }

    /// The shipped policy is a real position rather than report-only, and the
    /// distinction is the whole reason this feature is wired to anything: the
    /// mitigation is local, so unlike pinning and attestation it does not need a
    /// server that does not exist.
    @Test("The shipped policy restricts on strong signals")
    func shippedPolicyIsNotObserveOnly() {
        #expect(AppContainer.defaultIntegrityPolicy == .restrictOnStrongSignals)
        #expect(AppContainer.defaultIntegrityPolicy.response != .observe)
    }
}
