import Darwin
import Foundation
import MachO

// MARK: - Constants the SDK does not hand over

/// `MH_MAGIC_64` from `<mach-o/loader.h>`.
///
/// Written out rather than imported. The C macro reaches Swift as a differently
/// signed integer type depending on the toolchain, so comparing against it needs
/// a conversion that is itself a place to be wrong; the value has not changed
/// since Mach-O grew a 64-bit form and will not.
private let machHeaderMagic64: UInt32 = 0xfeed_facf

/// `LC_ENCRYPTION_INFO_64` from `<mach-o/loader.h>`, for the same reason.
private let encryptionInfoCommand64: UInt32 = 0x2C

/// `P_TRACED` from `<sys/proc.h>`, which is not in the iOS SDK's Swift overlay
/// at all — the header is not modularised, so there is nothing to import.
private let processTracedFlag: Int32 = 0x0000_0800

// MARK: - The probe

/// The half of the heuristics that touches the system, and the half that cannot
/// be tested here.
///
/// It makes no judgements, and that is the whole shape of the design: every
/// method below answers one factual question about the running environment and
/// none of them knows what the answer means. `DeviceIntegrityEvaluator` is where
/// the meaning lives, because that half is a pure function and a test can hand it
/// any device state it likes — including the jailbroken one that will never exist
/// in CI.
///
/// So this type gathers on a simulator too, even though two of the observations
/// are meaningless there. `/bin/sh` and `/etc/apt` are on every Mac, so
/// `jailbreakArtefacts` comes back full on every CI run; the evaluator marks
/// those heuristics unassessable rather than the probe withholding them, so that
/// there is exactly one place in the codebase that decides what an observation is
/// worth.
///
/// ## What none of this can do
///
/// Every check here runs inside the process it is judging, using APIs that a
/// resident hooking framework has already replaced. `access` can be answered,
/// `sysctl` can be answered, the dyld image list can be filtered, and the
/// conditional that reads the result can be patched out of a binary somebody has
/// already decrypted. These raise the cost of a casual repackage from minutes to
/// an afternoon. They do not stop anybody who is trying. `docs/threat-model.md`
/// is the long version, and `IntegrityResponse` is why the app degrades rather
/// than refusing to run.
package struct SystemIntegrityProbe: IntegrityProbing {

    /// Paths that exist only once a jailbreak has been installed.
    ///
    /// Exposed so that `docs/threat-model.md` can be checked against the list
    /// rather than describing a list that has drifted, and so that this stays the
    /// only place in the package that names any of them —
    /// `Tools/assert-integrity-heuristics.py` enforces both.
    ///
    /// The list covers three generations, because a check that only knows about
    /// Cydia has not been updated since 2019: the classic `/Applications` entries,
    /// the Substrate-era `/Library/MobileSubstrate` and `/usr/lib` payloads, and
    /// the rootless layout under `/var/jb` that palera1n and Dopamine use and that
    /// most published snippets still miss entirely.
    ///
    /// Deliberately absent: `/bin/bash` and `/bin/sh`. They are on every Mac, so
    /// including them would make the artefact heuristic fire on every simulator
    /// run — and while the evaluator would discard it, a list that cannot be read
    /// as "these mean something" is a list nobody maintains.
    package static let artefactPaths: [String] = [
        // Package managers and their installers.
        "/Applications/Cydia.app",
        "/Applications/Sileo.app",
        "/Applications/Zebra.app",
        "/Applications/Installer.app",
        "/usr/libexec/cydia",
        "/private/var/lib/apt",
        "/private/var/lib/cydia",
        "/etc/apt",
        // Code-injection runtimes, on disk rather than loaded.
        "/Library/MobileSubstrate/MobileSubstrate.dylib",
        "/Library/MobileSubstrate/DynamicLibraries",
        "/usr/lib/libsubstrate.dylib",
        "/usr/lib/libhooker.dylib",
        "/usr/lib/substitute-inserter.dylib",
        "/usr/lib/TweakInject",
        // Remote access, which is what a jailbreak is usually installed for.
        "/usr/sbin/sshd",
        "/usr/libexec/sftp-server",
        "/etc/ssh/sshd_config",
        // The rootless layout. Modern jailbreaks put all of the above in here.
        "/var/jb",
        "/var/jb/usr/lib/TweakInject",
        "/var/jb/Library/MobileSubstrate/DynamicLibraries",
        // Left behind by older untethered jailbreaks.
        "/private/var/stash",
    ]

    /// Directories outside the app container that an intact sandbox refuses to
    /// report as writable.
    ///
    /// This is the stronger of the two filesystem heuristics, because it is the
    /// kernel answering about its own enforcement rather than a file being
    /// absent: under an intact sandbox every one of these is `EPERM` no matter
    /// what is installed on the device.
    ///
    /// It asks `access(2)` rather than writing a file and deleting it, which is
    /// the form most published implementations take. Creating a file outside the
    /// container leaves evidence of the probe on the device, and the path where
    /// the cleanup fails is exactly the compromised device the check exists for —
    /// so the version that writes nothing is both safer and the one that cannot
    /// leave a mess behind.
    package static let containerEscapePaths: [String] = [
        "/",
        "/private",
        "/Library",
        "/var/mobile",
    ]

    /// Lowercased substrings that name a code-injection framework, matched
    /// against the path of every loaded image.
    ///
    /// The strongest thing available from inside the process, and the only
    /// heuristic here that is about *this app* rather than about the device: a
    /// tweak that hooks this process has to be mapped into this process to do it,
    /// so it has to be in this list to be doing anything at all.
    package static let injectionMarkers: [String] = [
        "mobilesubstrate",
        "substrateloader",
        "substrateinserter",
        "libsubstrate",
        // Substitute's two payloads by name, and not the bare word "substitute":
        // a marker that is also an ordinary English word is a marker that will
        // one day match a framework path for reasons that have nothing to do
        // with code injection, and a false positive on this signal is the one
        // that withholds a credential.
        "libsubstitute",
        "substitute-inserter",
        "libhooker",
        "ellekit",
        "tweakinject",
        "rocketbootstrap",
        "libcycript",
        "cynject",
        "frida",
        "sslkillswitch",
        "libsparkapplist",
    ]

    // Whether this is a simulator. Compile-time, because it is a fact about the
    // build and there is nothing to be gained by asking at runtime — and because
    // a runtime answer is one an attacker would control. See
    // `DistributionChannel` for the same argument at greater length.
    #if targetEnvironment(simulator)
    package static let isSimulator = true
    #else
    package static let isSimulator = false
    #endif

    package init() {}

    package func observe() -> IntegrityObservations {
        IntegrityObservations(
            jailbreakArtefacts: Self.readableArtefacts(),
            writablePathsOutsideContainer: Self.writableEscapePaths(),
            injectedLibraries: Self.loadedInjectionFrameworks(),
            debuggerAttached: Self.isBeingTraced(),
            bundleIdentifier: Bundle.main.bundleIdentifier,
            provisioningProfilePresent: Self.hasProvisioningProfile(),
            mainExecutableEncryption: Self.mainExecutableEncryption(),
            runningInSimulator: Self.isSimulator
        )
    }

    // MARK: - Filesystem

    /// `access(2)` rather than `FileManager.fileExists`, which is the same
    /// question through two more layers of dispatch — each of which is one more
    /// thing to hook, and one of which is Objective-C and therefore swizzlable
    /// without any hooking at all.
    static func readableArtefacts() -> Set<String> {
        Set(artefactPaths.filter { access($0, F_OK) == 0 })
    }

    static func writableEscapePaths() -> Set<String> {
        Set(containerEscapePaths.filter { access($0, W_OK) == 0 })
    }

    // MARK: - This process

    static func loadedInjectionFrameworks() -> Set<String> {
        var found: Set<String> = []
        for index in 0..<_dyld_image_count() {
            guard let pointer = _dyld_get_image_name(index) else { continue }
            let name = FileManager.default.string(
                withFileSystemRepresentation: pointer,
                length: Int(strlen(pointer))
            )
            let lowered = name.lowercased()
            if injectionMarkers.contains(where: { lowered.contains($0) }) {
                found.insert(name)
            }
        }
        return found
    }

    /// `sysctl` rather than `ptrace(PT_DENY_ATTACH)`, which is the other thing
    /// this is usually written as and is a different feature: denying attachment
    /// is a mitigation, and a rejected one — it is a private call, it breaks every
    /// legitimate debugging session including the crash reporter's, and a
    /// jailbroken device removes it. This only asks whether a debugger is
    /// currently attached, and reports.
    static func isBeingTraced() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & processTracedFlag) != 0
    }

    // MARK: - This build

    static func hasProvisioningProfile() -> Bool {
        Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil
    }

    /// Walks the main executable's load commands for `LC_ENCRYPTION_INFO_64` and
    /// reports its `cryptid`.
    ///
    /// Image 0 is the main executable — dyld puts it there — which in a unit-test
    /// process means the test runner rather than the app. That is one more reason
    /// the evaluator, not this method, decides what the answer is worth.
    ///
    /// Every failure to read reports `.unreadable` rather than guessing.
    /// `MachOEncryptionState` has four cases precisely so that "I could not tell"
    /// is not spelled the same way as "it is not encrypted".
    static func mainExecutableEncryption() -> MachOEncryptionState {
        guard let base = _dyld_get_image_header(0) else { return .unreadable }
        let raw = UnsafeRawPointer(base)
        let header = raw.assumingMemoryBound(to: mach_header_64.self)
        guard header.pointee.magic == machHeaderMagic64 else { return .unreadable }

        var cursor = raw.advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let command = cursor.assumingMemoryBound(to: load_command.self)
            let size = Int(command.pointee.cmdsize)
            guard size > 0 else { return .unreadable }
            if command.pointee.cmd == encryptionInfoCommand64 {
                let info = cursor.assumingMemoryBound(to: encryption_info_command_64.self)
                return info.pointee.cryptid == 0 ? .notEncrypted : .encrypted
            }
            cursor = cursor.advanced(by: size)
        }
        return .noEncryptionLoadCommand
    }
}

// MARK: - The double

/// A probe that reports whatever it was handed.
///
/// This is what makes the evaluation testable: every device state worth a rule —
/// a rootless jailbreak, a resigned store build, a debugger on a TestFlight
/// install — is a value written down in a test rather than a device somebody has
/// to own.
package struct StubIntegrityProbe: IntegrityProbing {

    package let observations: IntegrityObservations

    package init(_ observations: IntegrityObservations = IntegrityObservations()) {
        self.observations = observations
    }

    package func observe() -> IntegrityObservations {
        observations
    }
}
