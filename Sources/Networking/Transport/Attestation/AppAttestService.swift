import DeviceCheck
import Foundation
import os

// MARK: - The seam over DeviceCheck

/// The four things App Attest can do, behind a protocol.
///
/// It exists because `DCAppAttestService` cannot run anywhere this package is
/// tested. `isSupported` is `false` on every simulator — the framework needs
/// the Secure Enclave and an app signed by a real team — so the CI suite runs
/// on a device where the live implementation can only ever answer "no". A test
/// that exercised the real service would therefore be a test that exercises the
/// unsupported branch and nothing else, which is how an attestation path ships
/// having never produced a single assertion.
///
/// Everything above this protocol — the key lifecycle, the client data, the
/// headers, the enforcement decision, the retry — is ordinary Swift with no
/// Secure Enclave in it, and all of it is tested against `StubAppAttestService`.
/// What is *not* tested, and cannot be here, is the two-line body of each
/// `DeviceCheckAttestService` method. `docs/app-attest.md` says what a device
/// run has to confirm before an adopter turns enforcement on.
package protocol AppAttestGenerating: Sendable {

    /// Whether this device can attest at all.
    ///
    /// `false` on a simulator, on a device whose Secure Enclave is unavailable,
    /// and in any process not signed with the team that owns the app ID. It is
    /// read once per attempt rather than cached, because Apple documents it as
    /// a value that can change while the app is running.
    var isSupported: Bool { get }

    /// Creates a new hardware-backed key pair and returns its identifier.
    ///
    /// The private key never leaves the Secure Enclave. The identifier is the
    /// only handle to it, and losing the identifier loses the key: there is no
    /// enumeration API, so an identifier that is not persisted is a key that
    /// can never be used again.
    func generateKey() async throws -> String

    /// Asks Apple to certify a freshly generated key, once.
    ///
    /// - Returns: A CBOR attestation object for the server to verify against
    ///   Apple's App Attest root. It is not a credential and it is not secret;
    ///   it is only useful to a server holding the challenge it was bound to.
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data

    /// Signs `clientDataHash` with an already-attested key.
    ///
    /// Each call increments a counter inside the Secure Enclave that the
    /// assertion carries, which is what lets a server refuse a replay: an
    /// assertion whose counter is not strictly greater than the last one it
    /// accepted for this key has been seen before.
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

// MARK: - The live implementation

/// `AppAttestGenerating` backed by `DCAppAttestService`.
///
/// Stateless by construction: `DCAppAttestService.shared` is read at each call
/// rather than stored. Holding it would make this type carry a non-`Sendable`
/// reference for no benefit — the class has no per-instance state a caller can
/// configure, and `isSupported` is documented as changeable at runtime, so a
/// stored instance would not save a single answer.
package struct DeviceCheckAttestService: AppAttestGenerating {

    package init() {}

    package var isSupported: Bool {
        DCAppAttestService.shared.isSupported
    }

    package func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    package func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }

    package func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}

// MARK: - Reading what DeviceCheck threw

extension Error {

    /// Whether this is DeviceCheck telling us the key it was handed is no
    /// longer usable.
    ///
    /// `DCError.invalidKey` is the one failure that the client can actually
    /// repair, and repairing it means throwing the stored identifier away and
    /// attesting a new key. It happens for reasons that have nothing to do with
    /// a bug: the app was restored onto a different device, the user reinstalled,
    /// or the key was generated and then never attested, which leaves an
    /// identifier that `generateAssertion` will refuse forever.
    ///
    /// Retrying the same key on this error is the defect it exists to prevent —
    /// an app that does so is an app that has bricked its own attestation until
    /// the next reinstall.
    var isInvalidAttestationKey: Bool {
        guard let deviceCheckError = self as? DCError else { return false }
        return deviceCheckError.code == .invalidKey
    }
}

// MARK: - The double

/// A scripted `AppAttestGenerating`, for tests and previews.
///
/// Not a stand-in for the Secure Enclave: the bytes it returns are fixtures,
/// not signatures, and nothing here verifies anything. What it reproduces is
/// the *protocol* of App Attest — one key identifier per `generateKey`, a
/// counter that increments per assertion, and the ability to start refusing a
/// key the way DeviceCheck does when it has been invalidated — because those
/// are the behaviours `AppAttestor` has to get right.
///
/// The state is behind an `OSAllocatedUnfairLock` rather than in an actor for
/// the reason `StubServerTrustEvaluator` is: the protocol is synchronous in
/// `isSupported` and the type has to be usable from a test's arrange phase
/// without an `await` on every line.
package final class StubAppAttestService: AppAttestGenerating {

    private struct State: Sendable {
        var isSupported: Bool
        var keysIssued: Int = 0
        var assertionCounter: UInt32 = 0
        var invalidKeys: Set<String> = []
        var generateKeyFailure: AttestationStubFailure?
        var attestFailure: AttestationStubFailure?
        var assertionFailure: AttestationStubFailure?
        var attestedHashes: [Data] = []
        var assertedHashes: [Data] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    package init(isSupported: Bool = true) {
        state = OSAllocatedUnfairLock(initialState: State(isSupported: isSupported))
    }

    // MARK: - Arranging

    /// Makes every future call for `keyID` fail the way DeviceCheck does once a
    /// key has been invalidated.
    package func invalidate(_ keyID: String) {
        // `_ =` because `Set.insert` returns `(inserted:memberAfterInsert:)`,
        // which makes this a single-expression closure returning a tuple —
        // and a `withLock` whose result is discarded is a warning, which this
        // package treats as a build failure.
        state.withLock { _ = $0.invalidKeys.insert(keyID) }
    }

    /// Makes the next `generateKey()` throw.
    package func failGenerateKey(with failure: AttestationStubFailure) {
        state.withLock { $0.generateKeyFailure = failure }
    }

    /// Makes the next `attestKey` throw.
    package func failAttestation(with failure: AttestationStubFailure) {
        state.withLock { $0.attestFailure = failure }
    }

    /// Makes the next `generateAssertion` throw.
    package func failAssertion(with failure: AttestationStubFailure) {
        state.withLock { $0.assertionFailure = failure }
    }

    // MARK: - Observing

    /// How many keys this stub has handed out.
    package var keysIssued: Int { state.withLock { $0.keysIssued } }

    /// The client-data hashes passed to `attestKey`, in order.
    package var attestedHashes: [Data] { state.withLock { $0.attestedHashes } }

    /// The client-data hashes passed to `generateAssertion`, in order.
    package var assertedHashes: [Data] { state.withLock { $0.assertedHashes } }

    // MARK: - AppAttestGenerating

    package var isSupported: Bool { state.withLock { $0.isSupported } }

    package func generateKey() async throws -> String {
        try state.withLock { current in
            if let failure = current.generateKeyFailure {
                current.generateKeyFailure = nil
                throw failure.error
            }
            current.keysIssued += 1
            return "stub-attest-key-\(current.keysIssued)"
        }
    }

    package func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try state.withLock { current in
            if current.invalidKeys.contains(keyID) { throw AttestationStubFailure.invalidKey.error }
            if let failure = current.attestFailure {
                current.attestFailure = nil
                throw failure.error
            }
            current.attestedHashes.append(clientDataHash)
            return Data("stub-attestation-for-\(keyID)".utf8)
        }
    }

    package func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try state.withLock { current in
            if current.invalidKeys.contains(keyID) { throw AttestationStubFailure.invalidKey.error }
            if let failure = current.assertionFailure {
                current.assertionFailure = nil
                throw failure.error
            }
            current.assertionCounter += 1
            current.assertedHashes.append(clientDataHash)
            return Data("stub-assertion-\(current.assertionCounter)-for-\(keyID)".utf8)
        }
    }
}

// MARK: - Failures a stub can be told to produce

/// The DeviceCheck failures worth reproducing, as values a test can hand to
/// `StubAppAttestService`.
///
/// They are built as real `DCError`-domain `NSError`s rather than as a bespoke
/// error type, because the code under test branches on the domain and the code:
/// a stub that threw its own enum would let `isInvalidAttestationKey` be wrong
/// and every test still pass.
package enum AttestationStubFailure: Sendable, Hashable {

    /// `DCError.invalidKey`: the key is gone and a new one has to be attested.
    case invalidKey

    /// `DCError.serverUnavailable`: Apple's attestation servers could not be
    /// reached. Transient, and the same key is still good.
    case serverUnavailable

    /// `DCError.featureUnsupported`: this device cannot attest.
    case featureUnsupported

    package var error: any Error {
        let code: DCError.Code = switch self {
        case .invalidKey: .invalidKey
        case .serverUnavailable: .serverUnavailable
        case .featureUnsupported: .featureUnsupported
        }
        return NSError(domain: DCError.errorDomain, code: code.rawValue)
    }
}
