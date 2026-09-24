import Core
import Foundation
import os

// MARK: - How hard attestation is enforced

/// What the app does with a request it could not attest.
///
/// The same two positions certificate pinning ships with, for the same reason:
/// the mechanism is complete either way, and which one is correct depends on a
/// server that a template cannot supply.
package enum AttestationEnforcement: Hashable, Sendable, CustomStringConvertible {

    /// Attach an assertion when one can be produced, and let the request go
    /// either way. Failures are logged and nothing else.
    ///
    /// **The position this boilerplate ships in**, and the position any adopter
    /// should roll out in first. A server that is not yet verifying assertions
    /// gains nothing from a client that refuses to send requests without them,
    /// and an app that enforces before the server verifies has built an outage
    /// with no upside.
    case reportOnly

    /// A request that cannot be attested is not sent.
    ///
    /// Correct only once the server rejects unattested requests anyway, at
    /// which point refusing locally turns a round trip into an immediate
    /// failure. Note what it also means: an App Attest outage at Apple, a
    /// device that cannot attest, and a server whose `/attest/challenge` is
    /// down each become a total loss of function. `docs/app-attest.md` lists
    /// what to confirm before turning this on.
    case enforced

    package var description: String {
        switch self {
        case .reportOnly: "report-only"
        case .enforced: "enforced"
        }
    }
}

// MARK: - Reporting

/// Something the attestor did or could not do.
package enum AttestationEvent: Hashable, Sendable {

    /// A request went out carrying an assertion. The ordinary case.
    case attested(path: String, keyID: String)

    /// A key was generated, certified by Apple, and accepted by the server.
    /// Once per install, unless something invalidates it.
    case keyRegistered(keyID: String)

    /// DeviceCheck refused a key this app had stored, so it was discarded and
    /// a new one attested. Expected after a restore onto another device or a
    /// reinstall; unexpected in any other circumstance, and worth a look if it
    /// happens repeatedly.
    case keyInvalidated(keyID: String)

    /// This device cannot attest at all.
    case unsupportedDevice(enforcement: AttestationEnforcement)

    /// An attempt failed. `reason` is a description rather than the error,
    /// because an event has to be `Hashable` to be compared in a test and
    /// `any Error` is not.
    case failed(path: String, reason: String, enforcement: AttestationEnforcement)

    /// An attempt was not made, because a previous one failed recently enough
    /// that the next is not yet worth the round trip.
    case coolingDown(path: String, until: Date)
}

/// Where attestation events go.
package protocol AttestationReporting: Sendable {
    func report(_ event: AttestationEvent)
}

/// The default: the unified log, under the app's own subsystem.
///
/// The key identifier is logged as a public value. It is not a credential — it
/// is a handle to a key whose private half cannot leave the Secure Enclave —
/// and a failure report that cannot say which key failed is a failure report
/// nobody can correlate with the server's own log.
package struct OSLogAttestationReporter: AttestationReporting {
    private let logger: Logger

    package init(subsystem: String) {
        logger = Logger(subsystem: subsystem, category: "app-attest")
    }

    package func report(_ event: AttestationEvent) {
        switch event {
        case let .attested(path, keyID):
            logger.debug("Attested \(path, privacy: .public) with key \(keyID, privacy: .public)")
        case let .keyRegistered(keyID):
            logger.notice("Registered App Attest key \(keyID, privacy: .public)")
        case let .keyInvalidated(keyID):
            logger.notice("App Attest key \(keyID, privacy: .public) was invalidated; attesting a new one")
        case let .unsupportedDevice(enforcement):
            logger.error("App Attest is unsupported on this device (\(enforcement.description, privacy: .public))")
        case let .failed(path, reason, enforcement):
            let detail = "\(enforcement.description): \(reason)"
            logger.error("Could not attest \(path, privacy: .public) — \(detail, privacy: .public)")
        case let .coolingDown(path, until):
            let when = until.ISO8601Format()
            logger.debug("Not attesting \(path, privacy: .public); retrying after \(when, privacy: .public)")
        }
    }
}

/// A reporter that keeps what it was told, for tests and previews.
package final class RecordingAttestationReporter: AttestationReporting {
    private let state = OSAllocatedUnfairLock(initialState: [AttestationEvent]())

    package init() {}

    /// Everything reported so far, in order.
    package var events: [AttestationEvent] { state.withLock { $0 } }

    package func report(_ event: AttestationEvent) {
        state.withLock { $0.append(event) }
    }
}

// MARK: - The seam the transport holds

/// Produces the attestation for one outgoing request, or declines to.
///
/// `nil` means "send this request unattested", which under
/// `AttestationEnforcement.reportOnly` is every failure and on a simulator is
/// every request. Under `.enforced` the implementation throws instead, so a
/// caller cannot accidentally treat "could not attest" as "did not need to".
package protocol RequestAttesting: Sendable {
    func attestation(for request: URLRequest) async throws -> RequestAttestation?
}

/// An attestor that attests nothing.
///
/// Named, and required at the call site, rather than available as a default
/// argument on the transport. `URLSessionAPIClient` makes the same demand of
/// its `URLSession` for the same reason: a security control that can be
/// switched off by leaving an argument out is one that is eventually switched
/// off by leaving an argument out, in a diff where nothing appears.
package struct UnattestedRequests: RequestAttesting {
    package init() {}

    package func attestation(for request: URLRequest) async throws -> RequestAttestation? {
        nil
    }
}

// MARK: - AppAttestor

/// Holds the App Attest key for this install and signs each outgoing request
/// with it.
///
/// ## The key is registered once and then it is the app's identity
///
/// `generateKey` makes a Secure Enclave key pair; `attestKey` gets Apple to
/// certify that it belongs to a genuine install of this app; the server stores
/// the public half against that identifier. From then on every request carries
/// an assertion from the same key, and the server can tell this install from a
/// script with a stolen access token. So the registration has to happen exactly
/// once — which is why it runs inside this actor behind a single `Task` that
/// concurrent callers await rather than duplicate. Two registrations racing
/// would leave one certified key stored and another orphaned in the Enclave.
///
/// ## Why the identifier is in the Keychain and not `UserDefaults`
///
/// Apple's own sample writes it to `UserDefaults`, and there is a real argument
/// for that: the key dies with the install, and so does `UserDefaults`, whereas
/// a Keychain item outlives a reinstall and leaves a stored identifier pointing
/// at a key that no longer exists.
///
/// This stores it in the Keychain anyway, under
/// `afterFirstUnlockThisDeviceOnly` — the same accessibility as the session
/// tokens, because a background refresh has to attest with the device locked
/// and nobody there to authenticate. Two reasons. `ThisDeviceOnly` keeps the
/// identifier off backups and out of a restore onto another device, which is
/// the case where a carried-over identifier is *guaranteed* to be wrong.
/// And the stale-identifier path has to exist regardless: a key can be
/// invalidated by the system at any time, so `DCError.invalidKey` is handled
/// below whatever the storage choice, and handling it is what makes the
/// reinstall case cost one refused assertion rather than a broken install.
///
/// ## The breaker
///
/// Every attested request costs a challenge round trip. When the attestation
/// endpoints are down — or, in this template, not implemented at all, because
/// `api.example.com` does not exist — that is a guaranteed-failing extra
/// request in front of every real one. So a failure opens a breaker for
/// `cooldown` seconds, during which requests go out unattested (or, under
/// `.enforced`, fail immediately without the round trip). The first success
/// closes it again.
package actor AppAttestor: RequestAttesting {

    /// The Keychain account the key identifier lives under.
    ///
    /// Stated here, in the type that owns it, for the same reason
    /// `TokenStore.Keys` states the token accounts in the type that owns those:
    /// the account name and the policy protecting it have to be legible in one
    /// place, and `Tools/assert-token-storage.py` fails a second file that
    /// spells either out.
    package enum Keys {
        package static let keyIdentifier = "com.boilerplate.appAttestKeyIdentifier"
    }

    /// What protects the stored identifier. See the type's documentation for
    /// why it is the session tokens' accessibility and not a gated one.
    package static let keyPolicy = KeychainAccessPolicy.afterFirstUnlockThisDeviceOnly

    /// How long a failure suppresses the next attempt.
    package static let defaultCooldown: TimeInterval = 60

    private let service: any AppAttestGenerating
    private let server: any AttestationServing
    private let keychain: any KeychainStoring
    private let reporter: any AttestationReporting
    private let cooldown: TimeInterval
    private let now: @Sendable () -> Date

    /// How this attestor treats a request it cannot attest.
    package let enforcement: AttestationEnforcement

    private var cachedKeyID: String?
    private var inflightRegistration: Task<String, any Error>?
    private var resumeAttemptsAt: Date?

    /// - Parameters:
    ///   - cooldown: Seconds a failure suppresses the next attempt for.
    ///   - now: The clock, injected so a test can move it rather than sleep.
    package init(
        service: any AppAttestGenerating,
        server: any AttestationServing,
        keychain: any KeychainStoring,
        reporter: any AttestationReporting,
        enforcement: AttestationEnforcement,
        cooldown: TimeInterval = AppAttestor.defaultCooldown,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.server = server
        self.keychain = keychain
        self.reporter = reporter
        self.enforcement = enforcement
        self.cooldown = cooldown
        self.now = now
    }

    // MARK: - RequestAttesting

    package func attestation(for request: URLRequest) async throws -> RequestAttestation? {
        let path = request.url?.path ?? "?"

        guard service.isSupported else {
            reporter.report(.unsupportedDevice(enforcement: enforcement))
            return try declined(AttestationError.unsupportedDevice)
        }

        if let resumeAttemptsAt, now() < resumeAttemptsAt {
            reporter.report(.coolingDown(path: path, until: resumeAttemptsAt))
            return try declined(AttestationError.unattested)
        }

        do {
            let attestation = try await sign(request, replacingInvalidKey: true)
            resumeAttemptsAt = nil
            reporter.report(.attested(path: path, keyID: attestation.keyID))
            return attestation
        } catch {
            resumeAttemptsAt = now().addingTimeInterval(cooldown)
            let reason = (error as? AttestationError)?.errorDescription ?? error.localizedDescription
            reporter.report(.failed(path: path, reason: reason, enforcement: enforcement))
            return try declined(error)
        }
    }

    // MARK: - Signing

    /// Signs one request, replacing the key once if DeviceCheck refuses it.
    ///
    /// The recursion is bounded by the flag rather than by a counter: a second
    /// `invalidKey` on a key this call just registered is not a stale
    /// identifier, it is a device that will not attest, and retrying it in a
    /// loop turns that into a hang.
    private func sign(_ request: URLRequest, replacingInvalidKey: Bool) async throws -> RequestAttestation {
        let keyID = try await registeredKeyID()
        do {
            let challenge = try await freshChallenge()
            guard let clientData = AttestationClientData(request: request, challenge: challenge) else {
                throw APIError.invalidURL
            }
            let assertion = try await service.generateAssertion(
                keyID,
                clientDataHash: clientData.clientDataHash
            )
            return RequestAttestation(clientData: clientData, keyID: keyID, assertion: assertion)
        } catch let error where error.isInvalidAttestationKey && replacingInvalidKey {
            discardKey(keyID)
            return try await sign(request, replacingInvalidKey: false)
        }
    }

    private func freshChallenge() async throws -> String {
        let challenge = try await server.challenge()
        guard challenge.isUsable(at: now()) else { throw AttestationError.challengeExpired }
        return challenge.value
    }

    // MARK: - The key

    /// The identifier of a key this app has registered, attesting one first if
    /// there is none.
    ///
    /// Concurrent callers share one registration. The `Task` is stored on the
    /// actor rather than awaited inline for the reason `TokenStore` stores its
    /// refresh: actor isolation serialises the *entry*, not the suspension, so
    /// two callers that both reach a bare `await` would both run it.
    private func registeredKeyID() async throws -> String {
        if let cachedKeyID { return cachedKeyID }

        if let stored = try? keychain.string(forKey: Keys.keyIdentifier), !stored.isEmpty {
            cachedKeyID = stored
            return stored
        }

        if let inflightRegistration {
            return try await inflightRegistration.value
        }

        // The registration's client data names the bare `/attest/key`
        // constant rather than the full path the request goes to. It is the
        // one client data the server rebuilds from a constant instead of from
        // a request it received — registration is a body it parses, not a URL
        // it has to canonicalise — so there is no base-URL prefix to agree on.
        // `docs/app-attest.md` writes the six lines out.
        let task = Task { [service, server, reporter] () async throws -> String in
            let keyID = try await service.generateKey()
            let challenge = try await server.challenge()
            let clientData = AttestationClientData(
                method: HTTPMethod.post.rawValue,
                path: URLSessionAttestationService.keyPath,
                challenge: challenge.value
            )
            let attestation = try await service.attestKey(
                keyID,
                clientDataHash: clientData.clientDataHash
            )
            try await server.registerKey(keyID, attestation: attestation, challenge: challenge.value)
            reporter.report(.keyRegistered(keyID: keyID))
            return keyID
        }
        inflightRegistration = task

        do {
            let keyID = try await task.value
            inflightRegistration = nil
            store(keyID)
            return keyID
        } catch {
            inflightRegistration = nil
            throw error
        }
    }

    /// Persists a freshly registered identifier.
    ///
    /// A Keychain write that fails is not fatal and is deliberately not thrown:
    /// the identifier is already in `cachedKeyID`, so this process keeps
    /// attesting with it, and the only cost of a failed write is one more
    /// registration on the next launch.
    private func store(_ keyID: String) {
        cachedKeyID = keyID
        try? keychain.set(keyID, forKey: Keys.keyIdentifier, policy: AppAttestor.keyPolicy)
    }

    /// Forgets a key DeviceCheck will not sign with any more.
    private func discardKey(_ keyID: String) {
        cachedKeyID = nil
        try? keychain.remove(forKey: Keys.keyIdentifier)
        reporter.report(.keyInvalidated(keyID: keyID))
    }

    /// Clears the stored key, so that the next request registers a new one.
    ///
    /// For sign-out: the key identifies the install rather than the person, so
    /// there is no privacy reason to rotate it, but an adopter whose server
    /// binds keys to accounts will want to — and doing it by hand from outside
    /// would mean naming the Keychain account in a second place.
    package func reset() {
        cachedKeyID = nil
        inflightRegistration = nil
        resumeAttemptsAt = nil
        try? keychain.remove(forKey: Keys.keyIdentifier)
    }

    // MARK: - Declining

    /// What to return, or throw, when there is no assertion to attach.
    private func declined(_ error: any Error) throws -> RequestAttestation? {
        switch enforcement {
        case .reportOnly:
            return nil
        case .enforced:
            throw error
        }
    }
}
