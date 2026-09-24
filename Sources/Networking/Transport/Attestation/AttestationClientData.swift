import CryptoKit
import Foundation

// MARK: - What the assertion actually signs

/// The bytes an App Attest assertion is bound to, and the one thing in this
/// feature both ends have to agree on exactly.
///
/// App Attest signs a 32-byte `clientDataHash` and says nothing about what that
/// hash is of. That choice is the whole security property: an assertion bound
/// to nothing but a nonce proves a request came from a genuine install of this
/// app and proves nothing about *which* request, so an attacker who can reach
/// the app's own traffic can lift the headers off a harmless `GET` and staple
/// them to a `POST` that moves money. Binding the method, the path, the query
/// and a digest of the body is what makes the assertion a statement about this
/// request rather than about the device.
///
/// ## The format
///
/// Five lines plus a version marker, joined with `\n`, encoded UTF-8:
///
/// ```
/// attest/v1
/// POST
/// /v1/transfers
/// currency=GBP&to=12345
/// e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
/// Y2hhbGxlbmdlLWZyb20tdGhlLXNlcnZlcg==
/// ```
///
/// Method uppercased; path exactly as it appears in the request line, leading
/// slash included; query exactly as sent, empty line when there is none; the
/// body as lowercase hex SHA-256, which is the digest of the empty string for a
/// body-less request rather than an empty line — a request with no body and one
/// with an empty body are the same request; and last the challenge, verbatim as
/// the server issued it.
///
/// The body is hashed rather than included because the server already has the
/// bytes and a multi-megabyte upload should not become a multi-megabyte string
/// in memory twice. Hex rather than base64 so that a mismatch is legible in a
/// log on both ends.
///
/// ## Why the version is a line and not just a header
///
/// `AttestationHeaderField.format` carries the same marker so the server knows
/// which reconstruction to attempt before it has done any work. But a header is
/// attacker-controlled, and a server that picks its verification format from an
/// attacker-supplied string has handed over the choice of which fields are
/// covered — downgrade to a version that omitted the body and the binding is
/// gone. So the marker is *inside* the signed bytes as well: the header selects,
/// the signature confirms, and a server that implements two versions must still
/// refuse any version it does not accept before it verifies anything.
/// `docs/app-attest.md` spells out the server side.
package struct AttestationClientData: Hashable, Sendable {

    /// The format marker, first line and header value alike.
    package static let format = "attest/v1"

    /// The digest of an empty body, which is what a body-less request signs.
    package static let emptyBodyDigest = AttestationClientData.hexDigest(of: Data())

    package let method: String
    package let path: String
    package let query: String
    package let bodyDigest: String
    package let challenge: String

    /// - Parameters:
    ///   - method: Uppercased on the way in, so a caller passing `"post"`
    ///     cannot produce bytes the server will never reconstruct.
    ///   - path: The request's path, leading slash included.
    ///   - query: The percent-encoded query string without its `?`, or `""`.
    ///   - body: The request body. `nil` and `Data()` hash identically.
    ///   - challenge: The server-issued challenge, verbatim.
    package init(
        method: String,
        path: String,
        query: String = "",
        body: Data? = nil,
        challenge: String
    ) {
        self.method = method.uppercased()
        self.path = path
        self.query = query
        bodyDigest = AttestationClientData.hexDigest(of: body ?? Data())
        self.challenge = challenge
    }

    /// The client data for `request`, or `nil` when the request has no URL that
    /// can be decomposed.
    ///
    /// `URLComponents` rather than `url.path` and `url.query`: `URLRequest`
    /// carries an absolute URL and the server sees a request line, so the two
    /// ends have to agree on which part of the URL is "the path" — and on a
    /// `baseURL` with its own path prefix, `url.path` is the answer that
    /// includes it, which is the one the server reconstructs from.
    package init?(request: URLRequest, challenge: String) {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        self.init(
            method: request.httpMethod ?? "GET",
            path: components.percentEncodedPath,
            query: components.percentEncodedQuery ?? "",
            body: request.httpBody,
            challenge: challenge
        )
    }

    // MARK: - The bytes

    /// The canonical representation, exactly as both ends must build it.
    package var canonicalForm: String {
        [
            AttestationClientData.format,
            method,
            path,
            query,
            bodyDigest,
            challenge,
        ].joined(separator: "\n")
    }

    /// `canonicalForm` as UTF-8.
    package var canonicalBytes: Data {
        Data(canonicalForm.utf8)
    }

    /// The 32 bytes handed to `attestKey` or `generateAssertion`.
    ///
    /// Named for DeviceCheck's own parameter, and deliberately not `hash`: a
    /// property called `hash` on a `Hashable` type sits one character away from
    /// the conformance's own `hash(into:)` and reads, at every call site, like
    /// the value that decides equality. It is not — it is the digest this
    /// request's assertion is bound to.
    package var clientDataHash: Data {
        Data(SHA256.hash(data: canonicalBytes))
    }

    // MARK: - Hex

    private static func hexDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - The headers

/// The header fields that carry an attestation, named once.
///
/// They are a type rather than five string literals because both the client and
/// the audit script need the same names, and a header this app sets under one
/// spelling and a server reads under another is a failure that looks exactly
/// like "attestation is not enabled yet".
package enum AttestationHeaderField {

    /// Which client-data format the assertion was built with. See
    /// `AttestationClientData` for why this is advisory and the signed copy is
    /// authoritative.
    package static let format = "X-Attest-Format"

    /// The App Attest key identifier the server verified at registration time.
    package static let keyID = "X-Attest-Key-Id"

    /// The challenge this assertion is bound to, so the server can look up
    /// whether it issued it and whether it is still unspent.
    package static let challenge = "X-Attest-Challenge"

    /// The base64 CBOR assertion object.
    package static let assertion = "X-Attest-Assertion"

    /// Every field above, for an audit or a test that wants to assert that a
    /// request carries all of them or none of them.
    package static let all = [format, keyID, challenge, assertion]
}

// MARK: - A built attestation

/// What one attested request carries: the headers, and the client data they
/// were derived from.
///
/// The client data is kept beside the headers rather than discarded because it
/// is what makes a failure diagnosable — a server rejecting an assertion and a
/// client that cannot say what it signed is an afternoon of guessing.
package struct RequestAttestation: Hashable, Sendable {
    package let clientData: AttestationClientData
    package let keyID: String
    package let assertion: Data

    package init(clientData: AttestationClientData, keyID: String, assertion: Data) {
        self.clientData = clientData
        self.keyID = keyID
        self.assertion = assertion
    }

    /// The headers to set on the request, ready to apply.
    package var headers: [String: String] {
        [
            AttestationHeaderField.format: AttestationClientData.format,
            AttestationHeaderField.keyID: keyID,
            AttestationHeaderField.challenge: clientData.challenge,
            AttestationHeaderField.assertion: assertion.base64EncodedString(),
        ]
    }

    /// Applies `headers` to `request`.
    package func apply(to request: inout URLRequest) {
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }
}
