import Foundation

// MARK: - Idempotency key

/// A client-generated identifier for one *logical* request, sent so a server can
/// recognise a repeat of it and answer with the original outcome instead of
/// performing the work twice.
///
/// ```swift
/// let key = IdempotencyKey()
/// // Every attempt of this one edit carries the same key.
/// try await repository.updateProfile(name: "Ada", idempotencyKey: key)
/// ```
///
/// ## The problem it solves, stated precisely
///
/// A `PATCH` that fails with a timeout has three possible histories and the
/// client cannot tell them apart: the request never arrived, it arrived and was
/// rejected, or it arrived, was applied, and the response died on the way back.
/// `RetryingUserRepository` is built entirely around that ambiguity — its
/// unkeyed write policy retries only the failures that *prove* non-delivery,
/// because everything else risks applying the write twice.
///
/// A key removes the ambiguity by moving the decision to the side that knows.
/// The server records the key with the outcome of the first request that
/// carried it; a second request with the same key is answered from that record
/// rather than executed. The client no longer has to infer whether a write
/// happened, so it can retry the failures that say nothing — a timeout, a 503,
/// a connection lost mid-flight — which is exactly the set that retrying exists
/// for and the set the unkeyed policy has to refuse.
///
/// ## Client-generated, and why that is the only workable end
///
/// The key has to exist *before* the first attempt, because the whole point is
/// that the first attempt may be the one whose answer is lost — a
/// server-assigned identifier arrives in a response the client may never see.
/// So it is minted on the device, and it is a v4 UUID: 122 random bits need no
/// coordination with anything, which is what lets any screen mint one without
/// asking a registry, and the collision probability is far below the rate at
/// which the rest of this stack is wrong about anything.
///
/// ## Scope: one key is one intent, not one attempt
///
/// The key identifies the *intent* — "set my name to Ada" — and therefore
/// spans every attempt made on its behalf, including the token-refresh retry
/// inside `URLSessionAPIClient`, which is a second delivery of the same request
/// by a layer no policy above it can see. A key regenerated per attempt is
/// worse than no key at all: it costs a header and buys nothing, while reading
/// as though duplicates were handled. `UserRepository.updateProfile(name:)`
/// mints one per call for that reason — a caller that wants two edits gets two
/// keys, and a caller that wants one edit retried gets one key.
///
/// What it deliberately does *not* span is a process: a key lives in memory for
/// the duration of the call. Replaying an edit after a relaunch means the key
/// has to have been written down beside the pending edit, which is the outbox —
/// see `docs/idempotency.md`.
///
/// ## Validation
///
/// This value ends up verbatim in an HTTP header, so the initialiser that takes
/// a caller's string is failable rather than trusting. A string carrying CR or
/// LF would let a caller append headers of their own to the request, and one
/// carrying non-ASCII is not encodable in a header field at all. `init()` — the
/// generated case, and the one production uses — cannot produce either.
package struct IdempotencyKey: RawRepresentable, Hashable, Sendable, CustomStringConvertible {

    /// The header this is sent in.
    ///
    /// `Idempotency-Key` rather than a vendor-prefixed spelling: it is the name
    /// in the IETF draft (`draft-ietf-httpapi-idempotency-key-header`) and the
    /// one every major payments API already uses, so a server-side library that
    /// implements the behaviour at all implements it under this name.
    package static let headerField = "Idempotency-Key"

    /// The longest key this type will carry.
    ///
    /// Chosen to sit under any plausible server-side column and well under the
    /// per-header limits of the common proxies, so a key can never be the
    /// reason a request is rejected with a 431.
    package static let maxLength = 255

    /// Whether `scalar` may appear in a key: ASCII letters, digits, and `-._~`.
    ///
    /// The unreserved set from RFC 3986. It is a deliberate narrowing rather
    /// than "whatever a header can hold" — a key is very often echoed into a
    /// log line, a URL and a database key on the server, and the set that is
    /// safe in all three is smaller than the set that is legal in a header.
    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "-", ".", "_", "~":
            true
        default:
            false
        }
    }

    package let rawValue: String

    /// A fresh key for one new logical request.
    package init() {
        rawValue = UUID().uuidString
    }

    /// Adopts a key that already exists — one read back out of a persisted
    /// outbox row, or one a server handed the client to reuse.
    ///
    /// - Returns: `nil` if `rawValue` is empty, longer than ``maxLength``, or
    ///   contains anything outside the unreserved set.
    package init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue.count <= IdempotencyKey.maxLength,
              rawValue.unicodeScalars.allSatisfy({ IdempotencyKey.isAllowed($0) }) else {
            return nil
        }
        self.rawValue = rawValue
    }

    package var description: String { rawValue }
}
