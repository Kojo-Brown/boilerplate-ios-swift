import Foundation
import os
import Security

// MARK: - The result of looking at a server's trust

/// What the system thinks of a server's certificate chain, and what the chain's
/// keys pin to.
///
/// Both halves come back together because they are read from the same
/// `SecTrust` at the same moment, and because the order they are used in is not
/// negotiable: the chain has to be *valid* before its pins mean anything. A
/// pinned chain that the system rejects is still a rejected chain — pinning
/// narrows what is acceptable, it never widens it, and a delegate that returned
/// `.useCredential` on a pin match alone would have replaced the system's trust
/// store with a list of two hashes.
package struct ServerTrustEvaluation: Hashable, Sendable {

    /// Whether the chain validated against the system's anchors for the host.
    package let isTrusted: Bool

    /// The pin of every key in the chain the evaluation built, leaf first.
    ///
    /// A certificate whose key cannot be reduced to a pin contributes nothing
    /// here rather than contributing a placeholder, so it cannot match a
    /// policy. See `PublicKeyPinError`.
    package let pins: [PublicKeyPin]

    package init(isTrusted: Bool, pins: [PublicKeyPin]) {
        self.isTrusted = isTrusted
        self.pins = pins
    }
}

// MARK: - The seam

/// Evaluates a server's trust, so that the pinning decision can be tested
/// without a TLS handshake.
///
/// This is the one collaborator `CertificatePinningDelegate` cannot construct
/// for itself in a test: a `SecTrust` that the system *accepts* only exists at
/// the end of a real connection to a real host with a real certificate, and a
/// unit test has none of those. Splitting the evaluation out means every
/// branch of the decision — trusted and pinned, trusted and not pinned,
/// untrusted, expired policy — is reachable from a test, and
/// `SystemServerTrustEvaluator` keeps the one piece that genuinely needs the
/// Security framework.
package protocol ServerTrustEvaluating: Sendable {

    /// Validates `trust` for `host` and reads the pins of the chain it built.
    func evaluate(_ trust: SecTrust, host: String) -> ServerTrustEvaluation
}

// MARK: - The live evaluator

/// `SecTrustEvaluateWithError` plus `SecTrustCopyCertificateChain`, in that
/// order.
package struct SystemServerTrustEvaluator: ServerTrustEvaluating {

    package init() {}

    package func evaluate(_ trust: SecTrust, host: String) -> ServerTrustEvaluation {
        // Re-state the policy rather than inheriting whatever the caller left
        // on the trust. `URLSession` sets an SSL policy with the right
        // hostname before handing the challenge over, so this changes nothing
        // in production — but it is what makes the hostname this code checked
        // the hostname this code *knows* it checked, and it is what lets a
        // trust built by hand in a test be evaluated the same way.
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess else {
            return ServerTrustEvaluation(isTrusted: false, pins: [])
        }

        // The evaluation has to run before the chain is read: until it does,
        // `SecTrust` holds the certificates it was given rather than the chain
        // it built, and the two differ exactly when an intermediate was
        // supplied from the system's cache rather than by the server.
        let isTrusted = SecTrustEvaluateWithError(trust, nil)

        let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        let pins = chain.compactMap { try? PublicKeyPin(pinning: $0) }
        return ServerTrustEvaluation(isTrusted: isTrusted, pins: pins)
    }
}

// MARK: - The double

/// An evaluator that answers whatever a test told it to.
///
/// It lives here beside the protocol rather than in the test target for the
/// reason `MockAPIClient` does: the doubles are part of what this package
/// offers an adopter, and one that is compiled only under `swift test` is one
/// nobody can use from a preview.
///
/// The stub is behind a lock rather than under `@unchecked Sendable`, again
/// like `MockAPIClient`: a test that swaps the answer while a delegate is
/// mid-evaluation is then actually safe rather than merely asserted to be.
package final class StubServerTrustEvaluator: ServerTrustEvaluating {

    private struct State: Sendable {
        var evaluation = ServerTrustEvaluation(isTrusted: true, pins: [])
        var hostsAsked: [String] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package init(evaluation: ServerTrustEvaluation = ServerTrustEvaluation(isTrusted: true, pins: [])) {
        state.withLock { $0.evaluation = evaluation }
    }

    /// What `evaluate` will answer next.
    package var evaluation: ServerTrustEvaluation {
        get { state.withLock { $0.evaluation } }
        set { state.withLock { $0.evaluation = newValue } }
    }

    /// Every host the delegate asked about, in order. The delegate is supposed
    /// to stop before evaluating when it does not pin the host at all, and this
    /// is how a test sees that it did.
    package var hostsAsked: [String] {
        state.withLock { $0.hostsAsked }
    }

    package func evaluate(_ trust: SecTrust, host: String) -> ServerTrustEvaluation {
        state.withLock {
            $0.hostsAsked.append(host)
            return $0.evaluation
        }
    }
}
