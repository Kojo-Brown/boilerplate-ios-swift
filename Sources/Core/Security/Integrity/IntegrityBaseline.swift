import Foundation

// MARK: - Distribution channel

/// How this build was distributed.
///
/// Declared by the build, never detected at runtime, and that is the whole point
/// of the type. Every runtime test for "am I a store build?" — no provisioning
/// profile, a sandbox receipt, an encrypted `__TEXT` — is a test an attacker
/// controls the answer to, because they control the bundle. A build that asks
/// the bundle which rules apply to it has handed the choice of rules to whoever
/// repackaged it, and the rules they would switch off are precisely the ones
/// aimed at repackaging.
///
/// So the channel comes from the compiler (`#if DEBUG` in `AppContainer`) and
/// the runtime observations are then compared *against* it. That inversion is
/// what makes `IntegritySignal.provisioningProfileOnAStoreBuild` mean anything:
/// the profile is not evidence by itself, the disagreement between the profile
/// and the declaration is.
package enum DistributionChannel: String, Sendable, Hashable, Codable, CaseIterable {

    /// Built locally or by CI and run from Xcode, a simulator, or a test host.
    /// Signed for development, unencrypted, and routinely under a debugger.
    case development

    /// Distributed through TestFlight.
    case testFlight

    /// Distributed through the App Store.
    ///
    /// `.testFlight` and `.appStore` currently evaluate identically, and a
    /// reader should not go looking for the difference: both are signed by
    /// Apple, ship without an `embedded.mobileprovision`, and are
    /// FairPlay-encrypted, so every rule that distinguishes a distribution
    /// build from a development one treats them the same. They stay separate
    /// cases because the report carries the channel to whoever is triaging it,
    /// and "one TestFlight tester" and "the shipped app" are different news.
    case appStore

    /// Whether Apple signed and distributed this build.
    package var isDistribution: Bool {
        switch self {
        case .development: false
        case .testFlight, .appStore: true
        }
    }
}

// MARK: - Baseline

/// What this build knows about itself, against which the observations are read.
///
/// Small on purpose: two facts, both compile-time, both things the composition
/// root states rather than discovers. Anything that grows this type should be
/// asked the `DistributionChannel` question first — can the bundle lie about it?
package struct IntegrityBaseline: Sendable, Hashable, Codable {

    /// The bundle identifier this build was built to run under.
    ///
    /// A literal in the composition root, and deliberately not
    /// `Bundle.main.bundleIdentifier` — comparing a value against itself is a
    /// check that can never fail, which is the shape of most shipped
    /// anti-repackaging code. `AppContainer.logSubsystem` already exists for the
    /// same reason and says so.
    ///
    /// The cost is worth stating: in a unit-test process `Bundle.main` is the
    /// test runner, so a container built with the app's own baseline inside a
    /// test observes a mismatch and is right to. `DeviceIntegrityTests` asserts
    /// that rather than papering over it.
    package let expectedBundleIdentifier: String

    /// How this build was distributed. See `DistributionChannel`.
    package let channel: DistributionChannel

    package init(expectedBundleIdentifier: String, channel: DistributionChannel) {
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.channel = channel
    }
}
