import Foundation
import os
import Security

// MARK: - What the delegate decided

/// The three things a pinning delegate can conclude about a server.
package enum PinningDecision: Hashable, Sendable {

    /// The chain validated and one of its keys is pinned. The connection
    /// proceeds on a credential this delegate supplies.
    case pinned

    /// Nothing here is this delegate's business — the host is not pinned, the
    /// challenge is not a server-trust challenge, or the pins have expired.
    /// The connection proceeds on the system's own verdict, exactly as it
    /// would in an app with no pinning at all.
    case notPinned

    /// The connection is refused.
    case rejected(PinningRejection)
}

/// Why a connection was refused.
package enum PinningRejection: Hashable, Sendable {

    /// A server-trust challenge arrived for a pinned host with no `SecTrust`
    /// attached. This should not happen; if it does, the only safe reading is
    /// that there is nothing to check, and there is no version of "nothing to
    /// check" that satisfies a pin.
    case serverTrustUnavailable

    /// The chain failed the system's own evaluation. Pinning never rescues a
    /// chain the system rejects — it only narrows what the system accepts.
    case systemTrustRejected

    /// The chain is valid and carries no pinned key, under enforcement.
    case noPinMatched
}

// MARK: - Reporting

/// Something a pinning delegate saw.
///
/// The mismatch case is the one that has to reach somebody. A pin that stops
/// matching is not a bug that reproduces on a developer's machine: it happens
/// on one CDN edge, or behind one company's TLS-inspecting proxy, or for the
/// eleven hours between a CA re-issuing and a deploy going out. Under
/// `reportOnly` this event is the entire output of the feature, and under
/// `enforced` it is the only explanation the app will ever have for an outage
/// that otherwise looks like "the network is down".
package enum PinningEvent: Hashable, Sendable {

    /// A pinned key was found in a valid chain. The ordinary case, once per
    /// connection.
    case matched(host: String, pin: PublicKeyPin)

    /// A valid chain carried no pinned key.
    case mismatched(
        host: String,
        presented: [PublicKeyPin],
        expected: Set<PublicKeyPin>,
        enforcement: PinEnforcement
    )

    /// The system rejected the chain before pinning was reached.
    case systemTrustRejected(host: String)

    /// The host is pinned, but the pins have passed their expiry, so the
    /// connection fell through to the system's evaluation. See
    /// `HostPinningPolicy.expiry` for why that is the designed behaviour and
    /// not a failure — but it is worth knowing about, because it means an
    /// installed copy of the app has outlived its own pins.
    case policyExpired(host: String, expiry: Date)

    /// A server-trust challenge for a pinned host arrived with no `SecTrust`.
    case serverTrustUnavailable(host: String)
}

/// Where pinning events go.
package protocol PinningReporting: Sendable {
    func report(_ event: PinningEvent)
}

/// The default: the unified log, under the app's own subsystem.
///
/// A match logs at `debug` and everything else at `error`, which is the
/// difference between a line per request and a line that means something. The
/// hostname and the pins are interpolated as public values on purpose: a
/// mismatch report with the host redacted to `<private>` is a report nobody can
/// act on, and neither a hostname the app connects to nor the hash of a public
/// key is a secret.
package struct OSLogPinningReporter: PinningReporting {
    private let logger: Logger

    package init(subsystem: String) {
        logger = Logger(subsystem: subsystem, category: "certificate-pinning")
    }

    package func report(_ event: PinningEvent) {
        switch event {
        case let .matched(host, pin):
            logger.debug("Pinned \(host, privacy: .public) to \(pin.description, privacy: .public)")
        case let .mismatched(host, presented, expected, enforcement):
            let saw = presented.map(\.description).joined(separator: ", ")
            let wanted = expected.map(\.description).sorted().joined(separator: ", ")
            let detail = "\(enforcement): presented [\(saw)], expected [\(wanted)]"
            logger.error("Pin mismatch for \(host, privacy: .public) — \(detail, privacy: .public)")
        case let .systemTrustRejected(host):
            logger.error("System trust evaluation rejected the chain for \(host, privacy: .public)")
        case let .policyExpired(host, expiry):
            let when = expiry.ISO8601Format()
            logger.error("Pins for \(host, privacy: .public) expired at \(when, privacy: .public); not enforcing")
        case let .serverTrustUnavailable(host):
            logger.error("Server-trust challenge for \(host, privacy: .public) carried no trust object")
        }
    }
}

/// A reporter that keeps what it was told, for tests and previews.
package final class RecordingPinningReporter: PinningReporting {
    private let state = OSAllocatedUnfairLock(initialState: [PinningEvent]())

    package init() {}

    /// Everything reported so far, in order.
    package var events: [PinningEvent] { state.withLock { $0 } }

    package func report(_ event: PinningEvent) {
        state.withLock { $0.append(event) }
    }
}

// MARK: - CertificatePinningDelegate

/// Answers `URLSession`'s server-trust challenges against a pinning policy.
///
/// ## The order of the checks is the design
///
/// 1. Not a server-trust challenge, or not a host we pin → hand it back to the
///    system untouched. A pinning delegate that answers challenges it has no
///    opinion about is a pinning delegate that has quietly taken over client
///    certificates and HTTP authentication too.
/// 2. Pins expired → hand it back to the system, and say so. `HostPinningPolicy.expiry`
///    argues why the valve exists.
/// 3. Evaluate the chain against the system's anchors. **This comes before the
///    pin check, and a failure here is fatal regardless of the pins.** The
///    inverted version of this method — match a pin, return `.useCredential`,
///    never evaluate — is the single most common way pinning is implemented
///    wrongly, and it replaces the device's trust store with two hashes: an
///    expired certificate, a revoked one, or one issued for another hostname
///    all sail through as long as the key matches.
/// 4. Match any key in the built chain against the policy. Any key, rather
///    than the leaf only, because pinning an intermediate is a legitimate and
///    common choice — see `docs/certificate-pinning.md`.
/// 5. No match: refuse under `enforced`, and under `reportOnly` fall back to
///    the system's verdict, which we already know is "valid".
///
/// ## Lifetime
///
/// `URLSession` holds a strong reference to its delegate until the session is
/// invalidated, so a session built with one of these keeps it alive for the
/// session's lifetime. That is what the app wants — the session is created
/// once in `AppContainer.live()` and lives as long as the process — but it is
/// also why a test that builds sessions in a loop should invalidate them.
package final class CertificatePinningDelegate: NSObject, URLSessionDelegate, Sendable {

    private let policy: CertificatePinningPolicy
    private let evaluator: any ServerTrustEvaluating
    private let reporter: any PinningReporting
    private let now: @Sendable () -> Date

    /// `now` is injected because every expiry decision in this type depends on
    /// it, and a clock a test cannot move is a branch a test cannot reach.
    package init(
        policy: CertificatePinningPolicy,
        evaluator: any ServerTrustEvaluating = SystemServerTrustEvaluator(),
        reporter: any PinningReporting,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.policy = policy
        self.evaluator = evaluator
        self.reporter = reporter
        self.now = now
    }

    // MARK: - URLSessionDelegate

    package func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = response(to: challenge)
        completionHandler(disposition, credential)
    }

    // MARK: - The decision, reachable without a handshake

    /// What this delegate will tell `URLSession` about `challenge`.
    ///
    /// Four property reads and two calls. It is split this way because a test
    /// cannot reasonably build a `URLAuthenticationChallenge`: the initialiser
    /// demands a `URLAuthenticationChallengeSender`, and a `SecTrust` only
    /// reaches a protection space by subclassing it. Both halves of what this
    /// does are directly reachable instead — `decision(forHost:...)` decides,
    /// `disposition(for:trust:)` translates — so what is left untested here is
    /// the reading of `host`, `authenticationMethod` and `serverTrust` off a
    /// protection space, which is stated plainly rather than papered over with
    /// a test double that would only prove `URLProtectionSpace` has properties.
    package func response(
        to challenge: URLAuthenticationChallenge
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        let verdict = decision(
            forHost: space.host,
            authenticationMethod: space.authenticationMethod,
            trust: space.serverTrust
        )
        return disposition(for: verdict, trust: space.serverTrust)
    }

    /// The decision, as `URLSession` wants to hear it.
    ///
    /// `.pinned` is the only case that supplies a credential, and it supplies
    /// the very trust it just validated — not a bypass, since by then the
    /// chain has passed the system's own evaluation *and* carries a pinned
    /// key. `.notPinned` returns the challenge to the system untouched, which
    /// is deliberately not the same as accepting it: the system will apply its
    /// own anchors and may still refuse.
    package func disposition(
        for decision: PinningDecision,
        trust: SecTrust?
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        switch decision {
        case .pinned:
            guard let trust else { return (.cancelAuthenticationChallenge, nil) }
            return (.useCredential, URLCredential(trust: trust))
        case .notPinned:
            return (.performDefaultHandling, nil)
        case .rejected:
            return (.cancelAuthenticationChallenge, nil)
        }
    }

    /// The pinning decision itself. Reports as a side effect — see
    /// `PinningEvent` for why the reports are the point rather than a
    /// convenience.
    package func decision(
        forHost host: String,
        authenticationMethod: String,
        trust: SecTrust?
    ) -> PinningDecision {
        guard authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            return .notPinned
        }
        guard let hostPolicy = policy.policy(for: host) else {
            return .notPinned
        }
        if hostPolicy.hasExpired(at: now()) {
            reporter.report(.policyExpired(host: host, expiry: hostPolicy.expiry))
            return .notPinned
        }
        guard let trust else {
            reporter.report(.serverTrustUnavailable(host: host))
            return .rejected(.serverTrustUnavailable)
        }

        let evaluation = evaluator.evaluate(trust, host: host)
        guard evaluation.isTrusted else {
            reporter.report(.systemTrustRejected(host: host))
            return .rejected(.systemTrustRejected)
        }

        let expected = hostPolicy.pins.all
        if let match = evaluation.pins.first(where: expected.contains) {
            reporter.report(.matched(host: host, pin: match))
            return .pinned
        }

        reporter.report(
            .mismatched(
                host: host,
                presented: evaluation.pins,
                expected: expected,
                enforcement: hostPolicy.enforcement
            )
        )
        return hostPolicy.enforcement == .enforced ? .rejected(.noPinMatched) : .notPinned
    }
}
