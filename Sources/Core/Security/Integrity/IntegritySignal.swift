import Foundation

// MARK: - Confidence

/// How much weight one signal deserves on its own.
///
/// Two levels, not five. A scale finer than the evidence supports invites a
/// weighted score, and a score is the worst shape this can take: it collapses
/// "one strong observation" and "four weak ones" into the same number, and
/// nobody reading an alert can tell which they got. The report carries the
/// signals themselves for exactly that reason, and this only decides whether a
/// signal is enough, by itself, to change what the app does.
package enum IntegrityConfidence: Int, Sendable, Hashable, Comparable, CaseIterable {

    /// Consistent with a compromised device or a repackaged build, and also
    /// consistent with something ordinary. Worth reporting; not worth acting on
    /// alone.
    case moderate = 1

    /// Hard to produce without either a compromised device or a modified copy
    /// of this app. Still not proof — see `IntegrityPosture` — but enough to
    /// withhold a credential over.
    case strong = 2

    package static func < (lhs: IntegrityConfidence, rhs: IntegrityConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Category

/// Which question a signal answers.
///
/// The two are routinely conflated under "jailbreak detection" and they have
/// different consequences. A compromised *device* is the user's own doing far
/// more often than not — a false positive there costs a paying customer some
/// convenience. A modified *build* is not something a user does by accident, and
/// it is the case that actually indicates somebody working against the app.
package enum IntegrityCategory: String, Sendable, Hashable, Codable, CaseIterable {

    /// The operating system's guarantees are not the ones Apple shipped: the
    /// sandbox is not holding, or software that needs it not to be is installed.
    case jailbreak

    /// This is not the binary that was signed and shipped, or it is not loading
    /// only the code it was built from.
    case tamper

    /// Something is attached to the process and watching it run.
    case instrumentation
}

// MARK: - Signals

/// One thing the app noticed about the environment it is running in.
///
/// The raw values are the wire names. They are what a log line says and what a
/// server-side report would carry, so they are stable identifiers rather than
/// prose, and renaming one is a breaking change to anything triaging them.
///
/// Every case is raised by `DeviceIntegrityEvaluator` and named by
/// `docs/threat-model.md`; `Tools/assert-integrity-heuristics.py` fails if
/// either stops being true, because a signal nothing can raise is a heuristic
/// that does not exist and a signal nothing documents is one nobody can triage.
package enum IntegritySignal: String, Sendable, Hashable, Codable, CaseIterable {

    /// A path that only exists once a jailbreak has been installed is readable.
    ///
    /// The cheapest check there is, and the first one every tool defeats: the
    /// artefacts move (rootless jailbreaks live under `/var/jb`), and a hooking
    /// framework that wants to hide answers `stat` for the app.
    case jailbreakArtefactOnDisk = "jailbreak_artefact_on_disk"

    /// A directory outside this app's container reports as writable.
    ///
    /// Harder to fake than a path listing, because it is the sandbox itself
    /// answering rather than a file being absent. Under an intact sandbox every
    /// one of these is `EPERM` regardless of what is installed.
    case filesystemWritableOutsideContainer = "filesystem_writable_outside_container"

    /// A loaded image belongs to a code-injection framework.
    ///
    /// The strongest thing available in-process, and the only one of these that
    /// says something about *this app* rather than about the device: a tweak
    /// that hooks this process has to be in this process's image list to do it.
    case injectedLibraryLoaded = "injected_library_loaded"

    /// A debugger is attached to the process.
    ///
    /// `.moderate` because it is the developer's own workflow as often as it is
    /// anybody else's, which is why the evaluator does not even raise it on a
    /// development build.
    case debuggerAttached = "debugger_attached"

    /// The running bundle identifier is not the one this build declares.
    ///
    /// What a repackaged app looks like: the binary was re-signed under an
    /// identifier the attacker controls, because the original belongs to a team
    /// they do not have. It is also what a unit-test process looks like, since
    /// `Bundle.main` there is the test runner — see `IntegrityBaseline`.
    case bundleIdentifierMismatch = "bundle_identifier_mismatch"

    /// A distribution build is carrying an `embedded.mobileprovision`.
    ///
    /// App Store and TestFlight builds are signed by Apple and ship without
    /// one. A profile in a build that says it came from the store is what a
    /// copy re-signed with a development or enterprise certificate and
    /// sideloaded looks like.
    ///
    /// `.moderate` rather than `.strong` because it has an innocent
    /// explanation the others do not: a build configuration that declares
    /// `IntegrityBaseline.channel` as `.appStore` while actually being signed
    /// for development produces it on every launch, and that is a mistake in
    /// the build settings rather than an attack.
    case provisioningProfileOnAStoreBuild = "provisioning_profile_on_a_store_build"

    /// A distribution build's main executable is not FairPlay-encrypted.
    ///
    /// The store encrypts what it distributes, and `cryptid` is `0` only after
    /// somebody has dumped the decrypted image back out of memory and rebuilt a
    /// binary from it. That is the first step of every static-analysis workflow
    /// against an iOS app, so it is the one signal here that has no innocent
    /// explanation on a build that really did come from the store.
    case mainExecutableNotEncrypted = "main_executable_not_encrypted"

    /// What this signal is evidence about.
    package var category: IntegrityCategory {
        switch self {
        case .jailbreakArtefactOnDisk, .filesystemWritableOutsideContainer:
            .jailbreak
        case .injectedLibraryLoaded, .bundleIdentifierMismatch,
             .provisioningProfileOnAStoreBuild, .mainExecutableNotEncrypted:
            .tamper
        case .debuggerAttached:
            .instrumentation
        }
    }

    /// How much this signal is worth on its own. See `IntegrityConfidence`.
    package var confidence: IntegrityConfidence {
        switch self {
        case .jailbreakArtefactOnDisk,
             .filesystemWritableOutsideContainer,
             .injectedLibraryLoaded,
             .bundleIdentifierMismatch,
             .mainExecutableNotEncrypted:
            .strong
        case .debuggerAttached, .provisioningProfileOnAStoreBuild:
            .moderate
        }
    }
}
