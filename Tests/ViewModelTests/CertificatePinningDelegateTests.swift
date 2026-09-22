import Foundation
import Security
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Networking

// MARK: - The delegate's decision

/// The order of the checks, one test per branch.
///
/// The evaluator is substituted throughout, because the branch that matters
/// most — "the system rejected this chain" — cannot otherwise be produced: a
/// `SecTrust` the system *accepts* only exists at the end of a real handshake
/// with a real server. `SystemServerTrustEvaluatorTests` covers the live
/// evaluator against a real chain separately.
@Suite("What the pinning delegate decides, and in what order")
struct CertificatePinningDelegateTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let host = "api.example.com"

    private func policy(
        enforcement: PinEnforcement = .enforced,
        expiryDays: Double = 100
    ) throws -> CertificatePinningPolicy {
        let primary = try PinningFixture.leaf.pin
        let backup = try PinningFixture.backup.pin
        return CertificatePinningPolicy(
            hosts: [
                HostPinningPolicy(
                    host: host,
                    pins: PinSet(primary: primary, backup: backup),
                    expiry: now.addingTimeInterval(expiryDays * 24 * 60 * 60),
                    enforcement: enforcement
                ),
            ]
        )
    }

    private func delegate(
        policy: CertificatePinningPolicy,
        evaluator: StubServerTrustEvaluator,
        reporter: RecordingPinningReporter
    ) -> CertificatePinningDelegate {
        let clock = now
        return CertificatePinningDelegate(
            policy: policy,
            evaluator: evaluator,
            reporter: reporter,
            now: { clock }
        )
    }

    /// A trust object for the decision to carry. Its contents do not matter
    /// here: the substituted evaluator, not this, decides what the chain is.
    private func someTrust() throws -> SecTrust {
        let leaf = try PinningFixture.leaf.certificate
        return try PinningFixture.trust(over: [leaf])
    }

    @Test("A challenge that is not a server-trust challenge is not touched")
    func nonServerTrustChallengesAreLeftAlone() throws {
        let evaluator = StubServerTrustEvaluator()
        let reporter = RecordingPinningReporter()
        let subject = delegate(policy: try policy(), evaluator: evaluator, reporter: reporter)

        let decision = subject.decision(
            forHost: host,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
            trust: try someTrust()
        )

        #expect(decision == .notPinned)
        #expect(evaluator.hostsAsked.isEmpty)
        #expect(reporter.events.isEmpty)
    }

    @Test("A host the policy does not name is not touched, and costs no evaluation")
    func unpinnedHostsAreLeftAlone() throws {
        let evaluator = StubServerTrustEvaluator()
        let reporter = RecordingPinningReporter()
        let subject = delegate(policy: try policy(), evaluator: evaluator, reporter: reporter)

        let decision = subject.decision(
            forHost: "images.example.org",
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            trust: try someTrust()
        )

        #expect(decision == .notPinned)
        #expect(evaluator.hostsAsked.isEmpty)
    }

    /// The valve. Past the expiry the app behaves exactly like an app with no
    /// pinning, which is the designed outcome — but it is reported, because it
    /// means a build has outlived the pins it shipped with.
    @Test("Expired pins fall through to the system, and say so")
    func expiredPinsFallThrough() throws {
        let evaluator = StubServerTrustEvaluator()
        let reporter = RecordingPinningReporter()
        let expired = try policy(expiryDays: -1)
        let subject = delegate(policy: expired, evaluator: evaluator, reporter: reporter)
        let hostPolicy = try #require(expired.policy(for: host))

        let decision = subject.decision(
            forHost: host,
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            trust: try someTrust()
        )

        #expect(decision == .notPinned)
        #expect(evaluator.hostsAsked.isEmpty)
        #expect(reporter.events == [.policyExpired(host: host, expiry: hostPolicy.expiry)])
    }

    @Test("A server-trust challenge for a pinned host with no trust object is refused")
    func missingTrustIsRefused() throws {
        let evaluator = StubServerTrustEvaluator()
        let reporter = RecordingPinningReporter()
        let subject = delegate(policy: try policy(), evaluator: evaluator, reporter: reporter)

        let decision = subject.decision(
            forHost: host,
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            trust: nil
        )

        #expect(decision == .rejected(.serverTrustUnavailable))
        #expect(reporter.events == [.serverTrustUnavailable(host: host)])
    }

    /// The test this whole type exists for. Pinning narrows what the system
    /// accepts; it never widens it. A delegate that matched the pin first and
    /// returned `.useCredential` would accept this chain — expired, revoked,
    /// issued for another hostname, it makes no difference — because the key
    /// is the one it was told to expect.
    @Test("A chain the system rejects is refused even when a pinned key is in it")
    func systemRejectionWinsOverAPinMatch() throws {
        let reporter = RecordingPinningReporter()
        let pin = try PinningFixture.leaf.pin
        let evaluator = StubServerTrustEvaluator(
            evaluation: ServerTrustEvaluation(isTrusted: false, pins: [pin])
        )
        let subject = delegate(policy: try policy(), evaluator: evaluator, reporter: reporter)

        let decision = subject.decision(
            forHost: host,
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            trust: try someTrust()
        )

        #expect(decision == .rejected(.systemTrustRejected))
        #expect(reporter.events == [.systemTrustRejected(host: host)])
    }

    @Test("A valid chain carrying the primary key is pinned")
    func thePrimaryPinMatches() throws {
        let reporter = RecordingPinningReporter()
        let pin = try PinningFixture.leaf.pin
        let evaluator = StubServerTrustEvaluator(
            evaluation: ServerTrustEvaluation(isTrusted: true, pins: [pin])
        )
        let subject = delegate(policy: try policy(), evaluator: evaluator, reporter: reporter)

        let decision = subject.decision(
            forHost: host,
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            trust: try someTrust()
        )

        #expect(decision == .pinned)
        #expect(evaluator.hostsAsked == [host])
        #expect(reporter.events == [.matched(host: host, pin: pin)])
    }

    /// The rotation, demonstrated: the server has switched to the backup key
    /// and the *already installed* app accepts it, with no release in between.
    /// That is what the backup pin is for, and it is the one property of this
    /// design that cannot be read off the code.
    @Test("A valid chain carrying the backup key is pinned, with no app update")
    func theBackupPinMatches() throws {
        let reporter = RecordingPinningReporter()
        let rotated = try PinningFixture.backup.pin
        let evaluator = StubServerTrustEvaluator(
            evaluation: ServerTrustEvaluation(isTrusted: true, pins: [rotated])
        )
        let subject = delegate(policy: try policy(), evaluator: evaluator, reporter: reporter)

        let decision = subject.decision(
            forHost: host,
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            trust: try someTrust()
        )

        #expect(decision == .pinned)
        #expect(reporter.events == [.matched(host: host, pin: rotated)])
    }

    /// Pinning an issuer rather than the leaf is a legitimate choice — it
    /// survives every leaf renewal that CA performs — so a match anywhere in
    /// the chain counts.
    @Test("A pinned key further up the chain matches too")
    func anIssuerPinMatches() throws {
        let reporter = RecordingPinningReporter()
        let leafPin = try PinningFixture.leaf.pin
        let rootPin = try PinningFixture.root.pin
        let unrelated = try PinningFixture.backup.pin
        let policy = CertificatePinningPolicy(
            hosts: [
                HostPinningPolicy(
                    host: host,
                    pins: PinSet(primary: rootPin, backup: unrelated),
                    expiry: now.addingTimeInterval(100 * 24 * 60 * 60),
                    enforcement: .enforced
                ),
            ]
        )
        let evaluator = StubServerTrustEvaluator(
            evaluation: ServerTrustEvaluation(isTrusted: true, pins: [leafPin, rootPin])
        )
        let subject = delegate(policy: policy, evaluator: evaluator, reporter: reporter)

        let decision = subject.decision(
            forHost: host,
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            trust: try someTrust()
        )

        #expect(decision == .pinned)
        #expect(reporter.events == [.matched(host: host, pin: rootPin)])
    }

    @Test("A valid chain with no pinned key is refused under enforcement")
    func aMismatchIsRefusedWhenEnforcing() throws {
        let reporter = RecordingPinningReporter()
        let presented = try PinningFixture.root.pin
        let evaluator = StubServerTrustEvaluator(
            evaluation: ServerTrustEvaluation(isTrusted: true, pins: [presented])
        )
        let enforcing = try policy(enforcement: .enforced)
        let subject = delegate(policy: enforcing, evaluator: evaluator, reporter: reporter)

        let decision = subject.decision(
            forHost: host,
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            trust: try someTrust()
        )

        let hostPolicy = try #require(enforcing.policy(for: host))
        let expected = hostPolicy.pins.all

        #expect(decision == .rejected(.noPinMatched))
        #expect(
            reporter.events == [
                .mismatched(host: host, presented: [presented], expected: expected, enforcement: .enforced),
            ]
        )
    }

    /// The rollout position: the connection is allowed through on the system's
    /// own verdict and the mismatch is counted. A team that has never seen this
    /// event for a release cycle is a team that can safely turn enforcement on.
    @Test("A valid chain with no pinned key is allowed, and reported, under report-only")
    func aMismatchIsReportedWhenNotEnforcing() throws {
        let reporter = RecordingPinningReporter()
        let presented = try PinningFixture.root.pin
        let evaluator = StubServerTrustEvaluator(
            evaluation: ServerTrustEvaluation(isTrusted: true, pins: [presented])
        )
        let reporting = try policy(enforcement: .reportOnly)
        let subject = delegate(policy: reporting, evaluator: evaluator, reporter: reporter)

        let decision = subject.decision(
            forHost: host,
            authenticationMethod: NSURLAuthenticationMethodServerTrust,
            trust: try someTrust()
        )

        #expect(decision == .notPinned)
        #expect(reporter.events.count == 1)
    }

    // MARK: - How a decision reaches URLSession

    @Test("Only a pinned decision supplies a credential")
    func dispositionsMapAsURLSessionExpects() throws {
        let reporter = RecordingPinningReporter()
        let subject = delegate(
            policy: try policy(),
            evaluator: StubServerTrustEvaluator(),
            reporter: reporter
        )
        let trust = try someTrust()

        let pinned = subject.disposition(for: .pinned, trust: trust)
        #expect(pinned.0 == .useCredential)
        #expect(pinned.1 != nil)

        let unpinned = subject.disposition(for: .notPinned, trust: trust)
        #expect(unpinned.0 == .performDefaultHandling)
        #expect(unpinned.1 == nil)

        let rejected = subject.disposition(for: .rejected(.noPinMatched), trust: trust)
        #expect(rejected.0 == .cancelAuthenticationChallenge)
        #expect(rejected.1 == nil)

        // Belt and braces: `.pinned` without a trust cannot become a credential,
        // so it falls to a refusal rather than to default handling.
        let impossible = subject.disposition(for: .pinned, trust: nil)
        #expect(impossible.0 == .cancelAuthenticationChallenge)
    }
}

// MARK: - The live evaluator

/// The one suite that uses the real Security framework rather than a stub.
///
/// It tests the direction that can be tested honestly on a machine with no
/// network: a chain rooted in a CA nobody trusts is **refused**. The other
/// direction — the system accepting a chain — needs an anchor the system
/// already trusts, which a fixture is not and a unit test cannot manufacture;
/// asserting it here would mean installing a trust anchor to prove that trust
/// anchors work.
///
/// What it does establish alongside the refusal is that the evaluator reads the
/// chain it was handed: the leaf's pin comes back first, which is what every
/// delegate test above assumes.
@Suite("The system evaluator refuses what the system does not trust")
struct SystemServerTrustEvaluatorTests {

    @Test("A self-signed fixture chain is untrusted, and its leaf pin is still read")
    func aSelfSignedChainIsRefused() throws {
        let leaf = try PinningFixture.leaf.certificate
        let root = try PinningFixture.root.certificate
        let trust = try PinningFixture.trust(over: [leaf, root])

        let leafPin = try PinningFixture.leaf.pin

        let evaluation = SystemServerTrustEvaluator().evaluate(trust, host: PinningFixture.host)

        #expect(evaluation.isTrusted == false)
        #expect(evaluation.pins.first == leafPin)
    }
}

// MARK: - The session the app actually uses

@Suite("A pinned session carries the delegate")
struct PinnedURLSessionTests {

    @Test("URLSession.pinned installs a CertificatePinningDelegate")
    func theSessionCarriesTheDelegate() {
        let session = URLSession.pinned(
            policy: .unpinned,
            reporter: RecordingPinningReporter()
        )
        defer { session.invalidateAndCancel() }

        #expect(session.delegate is CertificatePinningDelegate)
    }
}
