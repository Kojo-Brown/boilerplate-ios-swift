import Foundation

// MARK: - Mach-O encryption

/// What the main executable's `LC_ENCRYPTION_INFO_64` load command says.
///
/// Four cases rather than a `Bool`, because "not encrypted" and "could not tell"
/// have opposite meanings and a boolean has to pick one of them to be wrong
/// about. A probe that cannot read its own Mach-O header reports `.unreadable`
/// and the evaluator raises nothing; a probe that read it and found `cryptid`
/// zero reports `.notEncrypted` and, on a distribution build, that is the signal.
package enum MachOEncryptionState: String, Sendable, Hashable, Codable, CaseIterable {

    /// `cryptid` is non-zero: this is the image as the store distributed it.
    case encrypted

    /// `cryptid` is zero: the load command is there and says the payload is in
    /// the clear, which is what a dumped-and-rebuilt binary looks like.
    case notEncrypted

    /// There is no encryption load command at all. Normal for a locally built
    /// binary and for every simulator build; it is not evidence of anything.
    case noEncryptionLoadCommand

    /// The header could not be walked. Reported rather than guessed.
    case unreadable
}

// MARK: - Observations

/// The raw facts one pass of the heuristics gathered, before anything has been
/// concluded from them.
///
/// This type is the seam, and it is the reason the evaluation logic is testable
/// at all. The alternative — a `isJailbroken()` that walks the filesystem and
/// returns a `Bool` — cannot be tested against a jailbroken device, because
/// there is not one in CI and there never will be. Splitting the pass into
/// "what did the device say" and "what does that mean" makes the second half a
/// pure function over a value a test can simply write down, and leaves only the
/// first half untestable. `Tools/assert-integrity-heuristics.py` enforces that
/// split by failing if the evaluator names a single system API.
///
/// Every field is a *description of an observation*, never a verdict. There is
/// no `isCompromised` here and there is deliberately nowhere to put one.
package struct IntegrityObservations: Sendable, Hashable {

    /// Paths from the probe's artefact list that came back readable.
    ///
    /// The paths themselves, not a count: a report saying "three artefacts" is
    /// untriageable, and one naming `/var/jb` says which family of jailbreak.
    package var jailbreakArtefacts: Set<String>

    /// Directories outside the app container that reported as writable.
    package var writablePathsOutsideContainer: Set<String>

    /// Loaded image paths that matched a code-injection framework.
    package var injectedLibraries: Set<String>

    /// Whether the kernel says this process is being traced.
    package var debuggerAttached: Bool

    /// The bundle identifier the process is actually running under, or `nil`
    /// when there is no main bundle identifier to read.
    package var bundleIdentifier: String?

    /// Whether an `embedded.mobileprovision` is present in the main bundle.
    package var provisioningProfilePresent: Bool

    /// What the main executable's encryption load command said.
    package var mainExecutableEncryption: MachOEncryptionState

    /// Whether this is a simulator.
    ///
    /// Load-bearing, not informational. A simulator's root filesystem is the
    /// Mac's: `/bin/sh`, `/usr/bin/ssh` and `/etc/apt` may all be right there,
    /// and `/private` may well be writable, so the two filesystem heuristics do
    /// not report a negative on a simulator — they report *nothing*, and the
    /// evaluator marks them unavailable. A check that fires unconditionally in
    /// CI is worse than no check: it is a check the team learns to ignore.
    package var runningInSimulator: Bool

    package init(
        jailbreakArtefacts: Set<String> = [],
        writablePathsOutsideContainer: Set<String> = [],
        injectedLibraries: Set<String> = [],
        debuggerAttached: Bool = false,
        bundleIdentifier: String? = nil,
        provisioningProfilePresent: Bool = false,
        mainExecutableEncryption: MachOEncryptionState = .noEncryptionLoadCommand,
        runningInSimulator: Bool = false
    ) {
        self.jailbreakArtefacts = jailbreakArtefacts
        self.writablePathsOutsideContainer = writablePathsOutsideContainer
        self.injectedLibraries = injectedLibraries
        self.debuggerAttached = debuggerAttached
        self.bundleIdentifier = bundleIdentifier
        self.provisioningProfilePresent = provisioningProfilePresent
        self.mainExecutableEncryption = mainExecutableEncryption
        self.runningInSimulator = runningInSimulator
    }
}

// MARK: - The seam

/// Gathers one pass of observations from the running environment.
///
/// Synchronous on purpose. Every probe behind it is a handful of `access(2)`
/// calls, one `sysctl`, a walk of the already-resident dyld image list and a
/// walk of one Mach-O header — microseconds in total, no I/O that can block —
/// and making it `async` would buy a suspension point in the middle of the
/// composition root for no benefit, while making it impossible to call from
/// anywhere that cannot await.
package protocol IntegrityProbing: Sendable {
    func observe() -> IntegrityObservations
}
