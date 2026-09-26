import Foundation

// MARK: - Posture

/// How much the signals that fired add up to.
///
/// Read the cases carefully, because the names are the honest ones and the
/// obvious names would be lies:
///
/// `.noSignals` does **not** mean the device is not jailbroken. It means every
/// heuristic that was able to run came back negative — and a device whose owner
/// has installed a hooking framework specifically to defeat these checks looks
/// exactly like this, because the checks run inside the process that framework
/// has already hooked. There is no in-process test that can distinguish the two,
/// which is why `docs/threat-model.md` opens by saying what this cannot do.
///
/// `.strongSignals` does not mean proof either. It means at least one thing was
/// observed that is hard to produce by accident, which is enough to withhold a
/// credential over and nowhere near enough to accuse anybody of anything.
package enum IntegrityPosture: Int, Sendable, Hashable, Comparable, CaseIterable, Codable,
    CustomStringConvertible {

    /// Nothing fired. See above for what that is not.
    case noSignals = 0

    /// Something fired, all of it `.moderate`.
    case moderateSignals = 1

    /// At least one `.strong` signal fired.
    case strongSignals = 2

    package static func < (lhs: IntegrityPosture, rhs: IntegrityPosture) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    package var description: String {
        switch self {
        case .noSignals: "no-signals"
        case .moderateSignals: "moderate-signals"
        case .strongSignals: "strong-signals"
        }
    }
}

// MARK: - Report

/// What one evaluation concluded.
///
/// The `unavailableHeuristics` set is the part that is easy to leave out and is
/// the reason this type is not just a `Set<IntegritySignal>`. A heuristic that
/// could not run is not a heuristic that passed, and collapsing the two is how a
/// suite of checks quietly becomes decorative: every filesystem heuristic here
/// is unavailable on a simulator, which is every run in CI, so a report that
/// said "no signals" would be reporting a clean bill of health from a set of
/// checks that never executed.
package struct IntegrityReport: Sendable, Hashable {

    /// The signals that fired.
    package let signals: Set<IntegritySignal>

    /// The signals that could not be assessed in this environment, and are
    /// therefore neither fired nor cleared.
    package let unavailableHeuristics: Set<IntegritySignal>

    /// What each fired signal was fired by, sorted so that two equal reports
    /// render identically. Empty for a signal whose evidence is its own
    /// occurrence, such as `.debuggerAttached`.
    package let evidence: [IntegritySignal: [String]]

    /// The build this was evaluated against.
    package let baseline: IntegrityBaseline

    package init(
        signals: Set<IntegritySignal>,
        unavailableHeuristics: Set<IntegritySignal>,
        evidence: [IntegritySignal: [String]],
        baseline: IntegrityBaseline
    ) {
        self.signals = signals
        self.unavailableHeuristics = unavailableHeuristics
        self.evidence = evidence
        self.baseline = baseline
    }

    /// The strongest thing any fired signal supports. See `IntegrityPosture`.
    package var posture: IntegrityPosture {
        switch signals.map(\.confidence).max() {
        case .none: .noSignals
        case .some(.moderate): .moderateSignals
        case .some(.strong): .strongSignals
        }
    }

    /// The signals that fired, in a stable order.
    package var firedInOrder: [IntegritySignal] {
        signals.sorted { $0.rawValue < $1.rawValue }
    }

    /// The signals that could not run, in a stable order.
    package var unavailableInOrder: [IntegritySignal] {
        unavailableHeuristics.sorted { $0.rawValue < $1.rawValue }
    }

    /// The fired signals in `category`, in a stable order.
    ///
    /// The split is the one `IntegrityCategory` exists for, and it is the one a
    /// triage queue needs rather than a total. A compromised *device* is the
    /// user's own doing far more often than not, and the cost of being wrong
    /// about it is a paying customer inconvenienced. A modified *build* is not
    /// something anybody does by accident, and it is the case that actually
    /// indicates somebody working against the app. A report that could only say
    /// "three signals" cannot tell those apart.
    package func signals(in category: IntegrityCategory) -> [IntegritySignal] {
        firedInOrder.filter { $0.category == category }
    }

    /// One line, deterministic, safe to log.
    ///
    /// It names the unavailable heuristics as well as the fired ones, because a
    /// log line that omits them reads as a clean run to whoever finds it six
    /// months later. It carries no path from `evidence`: an artefact path is
    /// harmless, but the habit of interpolating observed strings into a log is
    /// not, and the reporter logs the paths deliberately and separately.
    package var digest: String {
        let fired = firedInOrder.isEmpty ? "none" : firedInOrder.map(\.rawValue).joined(separator: ",")
        let skipped = unavailableInOrder.isEmpty
            ? "none"
            : unavailableInOrder.map(\.rawValue).joined(separator: ",")
        return "channel=\(baseline.channel.rawValue) posture=\(posture.description) "
            + "fired=\(fired) unavailable=\(skipped)"
    }
}
