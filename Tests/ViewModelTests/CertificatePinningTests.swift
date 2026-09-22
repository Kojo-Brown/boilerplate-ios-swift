import Foundation
import Security
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Networking

// MARK: - The pin itself

/// A pin is a hash of a DER structure that no API hands back, so `PublicKeyPin`
/// has to rebuild it. These are the tests that say it rebuilt the right one:
/// every expected value comes from `openssl`, not from this code. See
/// `PinningFixture`.
@Suite("A pin is the SHA-256 of a certificate's SubjectPublicKeyInfo")
struct PublicKeyPinTests {

    @Test(
        "Each fixture certificate pins to the value openssl computes",
        arguments: PinningFixture.all
    )
    func pinsMatchOpenSSL(fixture: PinningFixture.Certificate) throws {
        let pin = try fixture.pin
        #expect(pin.base64 == fixture.expectedPin, "\(fixture.name)")
        #expect(pin.description == "sha256/\(fixture.expectedPin)")
    }

    @Test("Three different keys pin to three different values")
    func distinctKeysPinDistinctly() throws {
        let pins = try PinningFixture.all.map { try $0.pin }
        #expect(Set(pins).count == pins.count)
    }

    @Test("A pin round-trips through its base64 form")
    func base64RoundTrips() throws {
        let pin = try PinningFixture.leaf.pin
        let recovered = PublicKeyPin(base64Encoded: pin.base64)
        #expect(recovered == pin)
    }

    /// The length check is the one that matters. A truncated or over-long pin
    /// can never match, and "never matches" is an outage under enforcement and
    /// a permanent alert under report-only — so a transcription error has to be
    /// refused where it is written down rather than discovered on the wire.
    @Test(
        "Anything that is not 32 decoded bytes is not a pin",
        arguments: [
            "",
            "AAAA",
            "bm90IGEgZGlnZXN0",
            "KP/N9ocBRCd3lGRvW094gKTiVWspfyq16bIFHI7cFg==",
            "KP/N9ocBRCd3lGRvW094gKTiVWspfyq16bIFHI7cFiIA",
            "this is not base64 at all",
        ]
    )
    func rejectsAnythingThatIsNotADigest(candidate: String) {
        #expect(PublicKeyPin(base64Encoded: candidate) == nil)
    }

    /// The placeholders have to be values no key can produce, or the safety
    /// check built on them — refusing to enforce a policy containing one —
    /// would be refusing a legitimate pin.
    @Test("The shipped placeholders are not the pin of any real key")
    func placeholdersAreNotRealKeys() throws {
        let real = try Set(PinningFixture.all.map { try $0.pin })
        #expect(real.isDisjoint(with: PublicKeyPin.placeholders))
        #expect(PublicKeyPin.placeholderPrimary != PublicKeyPin.placeholderBackup)
    }
}

// MARK: - The pin set

@Suite("A pin set is only a rotation plan if it can rotate")
struct PinSetTests {

    @Test("Every pin is accepted, including the additional ones")
    func allIncludesEveryPin() throws {
        let primary = try PinningFixture.leaf.pin
        let backup = try PinningFixture.backup.pin
        let extra = try PinningFixture.root.pin
        let set = PinSet(primary: primary, backup: backup, additional: [extra])

        #expect(set.all == [primary, backup, extra])
    }

    @Test("A backup that repeats the primary cannot rotate")
    func repeatedBackupCannotRotate() throws {
        let primary = try PinningFixture.leaf.pin
        let backup = try PinningFixture.backup.pin

        #expect(PinSet(primary: primary, backup: primary).canRotate == false)
        #expect(PinSet(primary: primary, backup: backup).canRotate)
    }
}

// MARK: - One host's policy

@Suite("A host policy governs exactly the hosts it says it does")
struct HostPinningPolicyTests {

    private func policy(host: String, includesSubdomains: Bool) throws -> HostPinningPolicy {
        let primary = try PinningFixture.leaf.pin
        let backup = try PinningFixture.backup.pin
        let pins = PinSet(primary: primary, backup: backup)
        return HostPinningPolicy(
            host: host,
            pins: pins,
            expiry: Date(timeIntervalSince1970: 2_000_000_000),
            enforcement: .enforced,
            includesSubdomains: includesSubdomains
        )
    }

    @Test("The host matches case-insensitively, because DNS does")
    func exactMatchIgnoresCase() throws {
        let subject = try policy(host: "api.example.com", includesSubdomains: false)

        #expect(subject.governs("api.example.com"))
        #expect(subject.governs("API.Example.COM"))
        #expect(subject.governs("other.example.com") == false)
    }

    @Test("A subdomain matches only when the policy asked for it")
    func subdomainsRequireOptingIn() throws {
        let closed = try policy(host: "example.com", includesSubdomains: false)
        let wildcard = try policy(host: "example.com", includesSubdomains: true)

        #expect(closed.governs("api.example.com") == false)
        #expect(wildcard.governs("api.example.com"))
    }

    /// The classic hostname-suffix bug: without the dot in the comparison,
    /// `evilapi.example.com` ends with `api.example.com` and is pinned by a
    /// policy written for a different host entirely.
    @Test("A hostname that merely ends with the pinned one does not match")
    func aSuffixIsNotASubdomain() throws {
        let subject = try policy(host: "api.example.com", includesSubdomains: true)

        #expect(subject.governs("evilapi.example.com") == false)
        #expect(subject.governs("eu.api.example.com"))
    }

    @Test("Expiry is inclusive: at the stated instant the pins are already off")
    func expiryIsInclusive() throws {
        let subject = try policy(host: "api.example.com", includesSubdomains: false)

        #expect(subject.hasExpired(at: subject.expiry))
        #expect(subject.hasExpired(at: subject.expiry.addingTimeInterval(-1)) == false)
    }
}

// MARK: - The whole policy, and its audit

@Suite("Looking a policy up, and auditing it")
struct CertificatePinningPolicyTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func soundPins() throws -> PinSet {
        let primary = try PinningFixture.leaf.pin
        let backup = try PinningFixture.backup.pin
        return PinSet(primary: primary, backup: backup)
    }

    private func host(
        _ name: String,
        expiryDays: Double = 100,
        enforcement: PinEnforcement = .enforced,
        pins: PinSet,
        includesSubdomains: Bool = false
    ) -> HostPinningPolicy {
        HostPinningPolicy(
            host: name,
            pins: pins,
            expiry: now.addingTimeInterval(expiryDays * 24 * 60 * 60),
            enforcement: enforcement,
            includesSubdomains: includesSubdomains
        )
    }

    @Test("An exact entry wins over a wildcard that would also match")
    func exactMatchWinsOverAWildcard() throws {
        let pins = try soundPins()
        let wildcard = host("example.com", pins: pins, includesSubdomains: true)
        let exact = host("api.example.com", pins: pins)
        let policy = CertificatePinningPolicy(hosts: [wildcard, exact])

        #expect(policy.policy(for: "api.example.com") == exact)
        #expect(policy.policy(for: "cdn.example.com") == wildcard)
        #expect(policy.policy(for: "example.org") == nil)
    }

    @Test("Pinning nothing is a policy, and it governs nothing")
    func theEmptyPolicyGovernsNothing() {
        #expect(CertificatePinningPolicy.unpinned.policy(for: "api.example.com") == nil)
        #expect(CertificatePinningPolicy.unpinned.problems(at: now).isEmpty)
    }

    @Test("A sound policy has nothing wrong with it")
    func aSoundPolicyHasNoProblems() throws {
        let pins = try soundPins()
        let policy = CertificatePinningPolicy(hosts: [host("api.example.com", pins: pins)])

        #expect(policy.problems(at: now).isEmpty)
    }

    @Test("The same host twice leaves one entry unreachable")
    func duplicateHostsAreReported() throws {
        let pins = try soundPins()
        let policy = CertificatePinningPolicy(
            hosts: [host("api.example.com", pins: pins), host("API.example.com", pins: pins)]
        )

        #expect(policy.problems(at: now).contains(.duplicateHost("API.example.com")))
    }

    @Test(
        "A host that is not a bare hostname can never match a connection",
        arguments: [
            "https://api.example.com",
            "api.example.com/v1",
            "api.example.com:443",
            ".api.example.com",
            "api.example.com.",
            "localhost",
            "",
        ]
    )
    func malformedHostsAreReported(name: String) throws {
        let pins = try soundPins()
        let policy = CertificatePinningPolicy(hosts: [host(name, pins: pins)])

        #expect(policy.problems(at: now).contains(.hostIsNotABareHostname(name)))
    }

    @Test("A backup that repeats the primary is reported")
    func aMissingBackupIsReported() throws {
        let pin = try PinningFixture.leaf.pin
        let policy = CertificatePinningPolicy(
            hosts: [host("api.example.com", pins: PinSet(primary: pin, backup: pin))]
        )

        #expect(policy.problems(at: now).contains(.backupRepeatsPrimary(host: "api.example.com")))
    }

    @Test("Expired pins, and pins valid for longer than the ceiling, are both reported")
    func expiryIsBoundedAtBothEnds() throws {
        let pins = try soundPins()
        let stale = host("api.example.com", expiryDays: -1, pins: pins)
        let forever = host("api.example.com", expiryDays: 400, pins: pins)
        let staleProblems = CertificatePinningPolicy(hosts: [stale]).problems(at: now)
        let foreverProblems = CertificatePinningPolicy(hosts: [forever]).problems(at: now)

        #expect(staleProblems.contains(.expiryHasPassed(host: "api.example.com", expiry: stale.expiry)))
        #expect(foreverProblems.contains(.expiryIsTooDistant(host: "api.example.com", expiry: forever.expiry)))
    }

    /// The safety catch on the template: enforcing the placeholder pins would
    /// produce an app that cannot reach any server at all, and the symptom
    /// would be an ordinary TLS failure that says nothing about pinning.
    @Test("Enforcing the template's placeholder pins is reported; reporting on them is not")
    func placeholderPinsCannotBeEnforced() {
        let placeholders = PinSet(primary: .placeholderPrimary, backup: .placeholderBackup)
        let enforced = host("api.example.com", enforcement: .enforced, pins: placeholders)
        let reportOnly = host("api.example.com", enforcement: .reportOnly, pins: placeholders)
        let enforcedProblems = CertificatePinningPolicy(hosts: [enforced]).problems(at: now)

        #expect(enforcedProblems.contains(.placeholderPinsAreEnforced(host: "api.example.com")))
        #expect(CertificatePinningPolicy(hosts: [reportOnly]).problems(at: now).isEmpty)
    }
}

// MARK: - The policy this app ships

/// The audit, run over the real value in the composition root.
///
/// `CertificatePinningPolicy.problems(at:)` is only worth having if something
/// calls it on the policy that ships, and this is that something.
@Suite("The policy AppContainer ships")
struct ShippedPinningPolicyTests {

    /// A fixed instant inside the shipped expiry window, so the structural
    /// checks below are about the policy rather than about what day it is.
    private let inWindow = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("It has nothing wrong with it")
    func theShippedPolicyIsSound() {
        #expect(AppContainer.defaultPinningPolicy.problems(at: inWindow).isEmpty)
    }

    @Test("It pins the host the app actually talks to")
    func itPinsTheDefaultBaseURLHost() throws {
        let host = try #require(AppContainer.defaultBaseURL.host())
        let policy = try #require(AppContainer.defaultPinningPolicy.policy(for: host))

        #expect(policy.host == host)
        #expect(policy.pins.canRotate)
    }

    /// Why this template ships `reportOnly`: the pins are placeholders, and a
    /// placeholder pin under enforcement is an app that can reach nothing.
    /// Turning enforcement on is one field — and doing it without replacing
    /// the pins fails the next test rather than shipping.
    @Test("Its placeholder pins are reported on, not enforced")
    func theShippedPinsAreNotEnforced() throws {
        let host = try #require(AppContainer.defaultBaseURL.host())
        let policy = try #require(AppContainer.defaultPinningPolicy.policy(for: host))

        #expect(policy.enforcement == .reportOnly)
        #expect(policy.pins.all.isSubset(of: PublicKeyPin.placeholders))
    }

    @Test("Enforcing it unchanged is refused by the audit")
    func enforcingTheTemplateUnchangedIsRefused() throws {
        let host = try #require(AppContainer.defaultBaseURL.host())
        let shipped = try #require(AppContainer.defaultPinningPolicy.policy(for: host))
        let enforced = HostPinningPolicy(
            host: shipped.host,
            pins: shipped.pins,
            expiry: shipped.expiry,
            enforcement: .enforced,
            includesSubdomains: shipped.includesSubdomains
        )

        let problems = CertificatePinningPolicy(hosts: [enforced]).problems(at: inWindow)
        #expect(problems == [.placeholderPinsAreEnforced(host: host)])
    }

    /// When this fails, the pins have outlived their expiry and the app has
    /// silently stopped pinning — which is `HostPinningPolicy.expiry` working
    /// as designed, and is the reminder it exists to be. The fix is to re-read
    /// `docs/certificate-pinning.md` and re-pin, not to move the date.
    @Test("Its pins have not expired yet")
    func theShippedPinsHaveNotExpired() throws {
        let host = try #require(AppContainer.defaultBaseURL.host())
        let policy = try #require(AppContainer.defaultPinningPolicy.policy(for: host))

        #expect(policy.hasExpired(at: Date()) == false)
    }
}
