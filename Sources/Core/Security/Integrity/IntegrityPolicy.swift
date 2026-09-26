import Foundation

// MARK: - What the app does about it

/// How the app responds to its own integrity report.
///
/// There is no `.terminate`, and its absence is the single most important design
/// decision in this file.
///
/// Refusing to run is the response every jailbreak-detection article reaches for
/// and it is the worst one available here, for two independent reasons. The first
/// is that it does not work: the check runs inside the process it is judging, so
/// on the device where it would matter the attacker owns the branch — patching
/// one conditional out of a binary they have already decrypted is the easiest
/// thing they will do all day, and the app they end up with is this app with the
/// check removed. The second is that it does work, on everybody else: the
/// heuristics here are heuristics, a false positive is not hypothetical, and the
/// cost of one is a paying customer holding an app that will not open and cannot
/// be talked through a fix. A mitigation whose failure mode is "cannot be used
/// at all" needs certainty behind it, and nothing in `IntegrityReport` is
/// certain.
///
/// So the responses that exist are the ones that degrade. `docs/threat-model.md`
/// carries the argument at length, including what a server is able to do with a
/// report that a client is not.
package enum IntegrityResponse: Sendable, Hashable, CustomStringConvertible {

    /// Evaluate, report, change nothing.
    ///
    /// The right position while the signals are being calibrated against real
    /// installs, and the only honest position for a signal whose false-positive
    /// rate nobody has measured yet.
    case observe

    /// Evaluate, report, and withhold the optional credential at or above this
    /// posture.
    ///
    /// "Withhold" is the whole of it: no screen is blocked, no session is ended,
    /// and nothing the user was already able to do stops working. See
    /// `IntegrityMitigations`.
    case restrict(atOrAbove: IntegrityPosture)

    package var description: String {
        switch self {
        case .observe:
            "observe"
        case .restrict(let posture):
            "restrict at or above \(posture.description)"
        }
    }
}

// MARK: - Mitigations

/// What the composition root should do differently, as a value it can read
/// without knowing why.
///
/// A value rather than a callback into the security code, because the decision
/// and its application live in different layers: `Core` is where the reasoning
/// belongs and it cannot see `TokenStore`, which is in `Networking`. Handing back
/// a `BiometricUnlockPolicy` would put an edge in the module graph that
/// `Tools/assert-module-boundaries.py` exists to refuse, and rightly — the
/// integrity code has no business knowing how credentials are stored.
package struct IntegrityMitigations: Sendable, Hashable {

    /// Whether to skip writing the biometric-gated duplicate of the refresh
    /// token.
    ///
    /// This is the one mitigation the app applies, and it was chosen because it
    /// is the one whose false positive costs nothing that matters. The gated
    /// copy exists so that the enrolled person can resume a session with a
    /// glance; withholding it means they type a password instead. Nobody is
    /// locked out, no data is lost, and the next launch reconsiders.
    ///
    /// What it buys: that record is a *second* copy of a live refresh token,
    /// kept only because an authentication gate stands in front of it. On a
    /// device where a hooking framework is resident, an `LAContext` evaluation
    /// is among the first things such a framework is used to lie about — so the
    /// gate is the part that fails first, and what is left is an extra
    /// credential in the Keychain with nothing guarding it. Not writing it is
    /// strictly a reduction in what can be stolen.
    ///
    /// What it does not buy: anything about the session tokens themselves, which
    /// are ungated by design because a background refresh has nobody to ask.
    /// `docs/security.md` is where that trade is argued.
    package let withholdsBiometricUnlockRecord: Bool

    /// Change nothing.
    ///
    /// Not spelled `none`: `IntegrityMitigations?` is a type this could plausibly
    /// be held as, and `.none` would then read as two different things in the
    /// same expression.
    package static let unchanged = IntegrityMitigations(withholdsBiometricUnlockRecord: false)

    package init(withholdsBiometricUnlockRecord: Bool) {
        self.withholdsBiometricUnlockRecord = withholdsBiometricUnlockRecord
    }
}

// MARK: - Policy

/// The app's standing decision about its own integrity reports.
package struct IntegrityPolicy: Sendable, Hashable {

    package let response: IntegrityResponse

    package init(response: IntegrityResponse) {
        self.response = response
    }

    /// Report and do nothing.
    package static let observe = IntegrityPolicy(response: .observe)

    /// What the app ships with: withhold the optional credential when at least
    /// one `.strong` signal fired.
    ///
    /// Deliberately not `.reportOnly`, which is where `CertificatePinningPolicy`
    /// and `AttestationEnforcement` both ship — and the difference is worth
    /// stating, because it is not inconsistency. Those two need a server that
    /// does not exist yet, so enforcing them in this template would mean an app
    /// that cannot send a request. This needs nothing: the mitigation is local,
    /// it costs a false positive one password entry, and the alternative is
    /// shipping a boilerplate whose security feature is wired up to nothing.
    ///
    /// `.moderateSignals` was the other candidate and was rejected. The two
    /// moderate signals are a debugger and a provisioning profile, and both have
    /// a build-configuration explanation — a team that mis-declares
    /// `IntegrityBaseline.channel` would have biometric unlock silently off in
    /// every build, which is the kind of failure that gets the whole mechanism
    /// deleted rather than fixed.
    package static let restrictOnStrongSignals = IntegrityPolicy(
        response: .restrict(atOrAbove: .strongSignals)
    )

    /// What to do about `report`.
    package func mitigations(for report: IntegrityReport) -> IntegrityMitigations {
        switch response {
        case .observe:
            .unchanged
        case .restrict(let threshold):
            IntegrityMitigations(withholdsBiometricUnlockRecord: report.posture >= threshold)
        }
    }
}
