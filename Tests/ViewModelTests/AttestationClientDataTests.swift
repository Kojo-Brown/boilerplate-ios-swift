import CryptoKit
import Foundation
import Testing
@testable import Core
@testable import Networking

// MARK: - The bytes both ends have to agree on

/// `AttestationClientData` is the only part of App Attest that a server has to
/// reimplement byte for byte, and the only part with no feedback loop: a client
/// that builds the bytes one way and a server that rebuilds them another get a
/// signature that verifies against nothing, with no message saying which field
/// disagreed. So the format is pinned here as a literal rather than as a
/// property — a test that rebuilt the expected string from the same fields
/// would pass through any change to the layout, which is precisely the change
/// that breaks a deployed server.
@Suite("App Attest — client data")
struct AttestationClientDataTests {

    private let emptyDigest = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()

    @Test("The canonical form is six lines in a fixed order")
    func canonicalFormIsPinned() {
        let clientData = AttestationClientData(
            method: "POST",
            path: "/v1/transfers",
            query: "currency=GBP",
            body: Data("{}".utf8),
            challenge: "challenge-1"
        )

        let bodyDigest = SHA256.hash(data: Data("{}".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(clientData.canonicalForm == """
        attest/v1
        POST
        /v1/transfers
        currency=GBP
        \(bodyDigest)
        challenge-1
        """)
    }

    @Test("The method is uppercased, so a lowercased caller cannot sign bytes the server never builds")
    func methodIsUppercased() {
        let clientData = AttestationClientData(method: "post", path: "/x", challenge: "c")
        #expect(clientData.method == "POST")
        #expect(clientData.canonicalForm.contains("\nPOST\n"))
    }

    @Test("No body and an empty body are the same request")
    func emptyBodyAndNoBodyAgree() {
        let absent = AttestationClientData(method: "GET", path: "/x", challenge: "c")
        let empty = AttestationClientData(method: "GET", path: "/x", body: Data(), challenge: "c")

        #expect(absent.bodyDigest == emptyDigest)
        #expect(absent.clientDataHash == empty.clientDataHash)
        #expect(AttestationClientData.emptyBodyDigest == emptyDigest)
    }

    @Test("The hash is 32 bytes and is the SHA-256 of the canonical bytes")
    func hashIsOverTheCanonicalBytes() {
        let clientData = AttestationClientData(method: "GET", path: "/x", challenge: "c")
        #expect(clientData.clientDataHash.count == 32)
        #expect(clientData.clientDataHash == Data(SHA256.hash(data: clientData.canonicalBytes)))
    }

    /// Each field in turn, because the failure this guards against is a field
    /// silently dropped from the canonical form: the assertion still verifies,
    /// and the thing it no longer says anything about is whichever field went
    /// missing.
    @Test("Every field is covered by the signature")
    func everyFieldChangesTheHash() {
        let base = AttestationClientData(
            method: "POST",
            path: "/v1/transfers",
            query: "currency=GBP",
            body: Data("{}".utf8),
            challenge: "challenge-1"
        )

        let variants = [
            AttestationClientData(
                method: "PUT", path: "/v1/transfers", query: "currency=GBP",
                body: Data("{}".utf8), challenge: "challenge-1"
            ),
            AttestationClientData(
                method: "POST", path: "/v1/refunds", query: "currency=GBP",
                body: Data("{}".utf8), challenge: "challenge-1"
            ),
            AttestationClientData(
                method: "POST", path: "/v1/transfers", query: "currency=USD",
                body: Data("{}".utf8), challenge: "challenge-1"
            ),
            AttestationClientData(
                method: "POST", path: "/v1/transfers", query: "currency=GBP",
                body: Data("{\"amount\":1}".utf8), challenge: "challenge-1"
            ),
            AttestationClientData(
                method: "POST", path: "/v1/transfers", query: "currency=GBP",
                body: Data("{}".utf8), challenge: "challenge-2"
            ),
        ]

        for variant in variants {
            #expect(variant.clientDataHash != base.clientDataHash)
        }
        #expect(Set(variants.map(\.clientDataHash)).count == variants.count)
    }

    // MARK: - From a URLRequest

    @Test("A request is decomposed into the path and query the server sees")
    func requestIsDecomposed() throws {
        let url = try #require(URL(string: "https://api.example.com/v1/users?page=2&size=10"))
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let clientData = try #require(AttestationClientData(request: request, challenge: "c"))

        #expect(clientData.method == "GET")
        #expect(clientData.path == "/v1/users")
        #expect(clientData.query == "page=2&size=10")
        #expect(clientData.bodyDigest == emptyDigest)
    }

    /// The `baseURL` this app ships with carries a `/v1` prefix, and a client
    /// that signed only the endpoint's own path would sign `/users` while the
    /// server rebuilt `/v1/users`.
    @Test("The path includes the base URL's own prefix")
    func pathIncludesTheBasePrefix() throws {
        let url = AppContainerBaseURLFixture.usersURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)

        let clientData = try #require(AttestationClientData(request: request, challenge: "c"))
        #expect(clientData.path == "/v1/users")
    }

    @Test("A request with no method is signed as the GET it will be sent as")
    func missingMethodIsGET() throws {
        let url = try #require(URL(string: "https://api.example.com/v1/users"))
        let request = URLRequest(url: url)
        let clientData = try #require(AttestationClientData(request: request, challenge: "c"))
        #expect(clientData.method == "GET")
    }

    // MARK: - Headers

    @Test("An attestation carries exactly the four declared header fields")
    func headersAreTheDeclaredFields() {
        let clientData = AttestationClientData(method: "GET", path: "/x", challenge: "challenge-1")
        let attestation = RequestAttestation(
            clientData: clientData,
            keyID: "key-1",
            assertion: Data("assertion-bytes".utf8)
        )

        #expect(Set(attestation.headers.keys) == Set(AttestationHeaderField.all))
        #expect(attestation.headers[AttestationHeaderField.format] == AttestationClientData.format)
        #expect(attestation.headers[AttestationHeaderField.keyID] == "key-1")
        #expect(attestation.headers[AttestationHeaderField.challenge] == "challenge-1")
        #expect(
            attestation.headers[AttestationHeaderField.assertion]
                == Data("assertion-bytes".utf8).base64EncodedString()
        )
    }

    @Test("Applying an attestation sets every field on the request")
    func applySetsEveryField() throws {
        let clientData = AttestationClientData(method: "GET", path: "/x", challenge: "challenge-1")
        let attestation = RequestAttestation(
            clientData: clientData,
            keyID: "key-1",
            assertion: Data("assertion-bytes".utf8)
        )
        let url = try #require(URL(string: "https://api.example.com/v1/x"))
        var request = URLRequest(url: url)

        attestation.apply(to: &request)

        for field in AttestationHeaderField.all {
            #expect(request.value(forHTTPHeaderField: field) == attestation.headers[field])
        }
    }

    // MARK: - Challenges

    @Test("A challenge with no stated expiry is usable")
    func challengeWithoutExpiryIsUsable() {
        let challenge = AttestationChallenge(value: "c")
        #expect(challenge.isUsable(at: Date(timeIntervalSince1970: 10_000)))
    }

    @Test("A challenge is usable up to its expiry and not past it")
    func challengeExpiry() {
        let expiry = Date(timeIntervalSince1970: 1_000)
        let challenge = AttestationChallenge(value: "c", expiresAt: expiry)

        #expect(challenge.isUsable(at: expiry.addingTimeInterval(-1)))
        #expect(!challenge.isUsable(at: expiry))
        #expect(!challenge.isUsable(at: expiry.addingTimeInterval(1)))
    }

    @Test("A challenge decodes from the server's snake-cased payload")
    func challengeDecodes() throws {
        let json = """
        {"challenge": "from-the-server", "expires_at": "2027-01-01T00:00:00Z"}
        """
        let challenge = try JSONDecoder.apiDecoder.decode(AttestationChallenge.self, from: Data(json.utf8))

        #expect(challenge.value == "from-the-server")
        #expect(challenge.expiresAt == Date(timeIntervalSince1970: 1_798_761_600))
    }

    @Test("A key registration encodes the attestation as base64 under snake-cased keys")
    func registrationEncodes() throws {
        let registration = AttestationKeyRegistration(
            keyID: "key-1",
            attestation: Data("attestation-bytes".utf8),
            challenge: "challenge-1"
        )

        let data = try JSONEncoder.apiEncoder.encode(registration)
        let object = try JSONSerialization.jsonObject(with: data)
        let decoded = try #require(object as? [String: String])

        #expect(decoded["key_id"] == "key-1")
        #expect(decoded["attestation"] == Data("attestation-bytes".utf8).base64EncodedString())
        #expect(decoded["challenge"] == "challenge-1")
    }
}

// MARK: - Fixture

/// The app's own base URL with a path appended, built the way the transport
/// builds one so that the prefix case above is measured against the real
/// composition rather than a string literal that agrees with itself.
private enum AppContainerBaseURLFixture {
    static let usersURL = URL(string: "https://api.example.com/v1")!.appendingPathComponent("/users")
}
