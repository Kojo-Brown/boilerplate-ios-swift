import CryptoKit
import Foundation
import Security

// MARK: - PublicKeyPin

/// The SHA-256 of a certificate's DER-encoded `SubjectPublicKeyInfo`.
///
/// This is the value a pin compares, and choosing *this* value rather than the
/// certificate's own fingerprint is the decision the whole rotation plan rests
/// on. A certificate expires; the key inside it does not have to. Pinning the
/// certificate means every renewal — annual at best, and same-day when a CA
/// re-issues after an incident — is a forced app update, so the pin that was
/// meant to survive a hostile CA is instead the thing that takes the app down
/// on a Tuesday. Pinning the key means a renewal that keeps the key is
/// invisible to the app, and `docs/certificate-pinning.md` is the plan for the
/// renewals that do not.
///
/// It is the same value `openssl` prints, so a pin can be read off a live
/// server rather than transcribed from a build:
///
/// ```
/// openssl s_client -connect api.example.com:443 -servername api.example.com \
///   | openssl x509 -pubkey -noout \
///   | openssl pkey -pubin -outform der \
///   | openssl dgst -sha256 -binary \
///   | base64
/// ```
///
/// `PublicKeyPinTests` pins that equivalence to fixture certificates whose pins
/// were computed by that exact pipeline — an EC P-256 key, an EC P-384 key and
/// an RSA-2048 key — because the equivalence is the one property of this type
/// that a reader cannot check by reading it.
package struct PublicKeyPin: Hashable, Sendable, CustomStringConvertible {

    /// How many bytes a SHA-256 digest is. A base64 string that decodes to any
    /// other length is not a pin, whatever else it is.
    package static let digestByteCount = SHA256.byteCount

    /// The digest itself, 32 bytes.
    package let digest: Data

    /// Hashes an already-encoded `SubjectPublicKeyInfo`.
    package init(hashing subjectPublicKeyInfo: Data) {
        digest = Data(SHA256.hash(data: subjectPublicKeyInfo))
    }

    /// Reads a pin back from the base64 form that configuration files, HTTP
    /// headers and `openssl` all use.
    ///
    /// Fails rather than truncating or padding: a pin that is the wrong length
    /// is a transcription error, and the safe response to a transcription error
    /// in a pin is to refuse it at the point it is written down. The
    /// alternative — accept it and compare — is a pin that can never match,
    /// which under enforcement is an app that cannot reach its own API and
    /// under report-only is an alert that never stops.
    package init?(base64Encoded: String) {
        guard let decoded = Data(base64Encoded: base64Encoded),
              decoded.count == Self.digestByteCount
        else { return nil }
        digest = decoded
    }

    /// The base64 form.
    package var base64: String { digest.base64EncodedString() }

    /// `sha256/<base64>`, the spelling HPKP used and the one every tool that
    /// prints a pin still uses. It names the hash function, which matters for a
    /// value whose whole meaning is "this hash of that key".
    package var description: String { "sha256/\(base64)" }
}

// MARK: - The placeholders this template ships

extension PublicKeyPin {

    /// The two pins in `AppContainer.defaultPinningPolicy`.
    ///
    /// They are `SHA256("boilerplate-ios-swift placeholder primary pin")` and
    /// the same for `backup` — deliberately not the hash of any key that has
    /// ever existed, in the same spirit as `AppContainer.defaultBaseURL`
    /// pointing at `api.example.com`.
    ///
    /// They are named here, rather than left as two anonymous base64 strings in
    /// the composition root, so that `CertificatePinningPolicy.problems(at:)`
    /// can refuse to let them be *enforced*. A template whose pins are
    /// placeholders and whose enforcement is on is an app that cannot reach any
    /// real server at all; the failure is total, it appears only against the
    /// live API, and the error it surfaces is an ordinary TLS failure that says
    /// nothing about pinning. That is a defect worth making unshippable rather
    /// than documenting.
    package static let placeholderPrimary = PublicKeyPin(
        base64Encoded: "EGeje8wx+E2FImVDQrEBGOZhhM1kplk9P9y9urQrERs="
    )!

    /// See `placeholderPrimary`.
    package static let placeholderBackup = PublicKeyPin(
        base64Encoded: "+A1h4+hTXI1W2B6O/FWIuxaWvVrW0j5o93YSMFcgf+M="
    )!

    /// Every pin this template ships with a value that is not a real key.
    package static let placeholders: Set<PublicKeyPin> = [placeholderPrimary, placeholderBackup]
}

// MARK: - Reading a pin off a certificate

/// Why a certificate's public key could not be reduced to a pin.
///
/// Every case is a *refusal to produce a pin*, never a pin that might be wrong,
/// because the caller's fallback is to compare against nothing: a certificate
/// that yields no pin cannot match the policy, and cannot satisfy it. Fail
/// closed is the only safe direction here, and it is reached by throwing rather
/// than by returning an empty value somebody could accidentally treat as a
/// match.
package enum PublicKeyPinError: Error, Hashable, Sendable {

    /// The certificate carried no public key `SecCertificateCopyKey` could read.
    case noPublicKey

    /// `SecKeyCopyAttributes` returned nothing, or nothing with the two
    /// attributes every key is documented to carry.
    case unreadableKeyAttributes

    /// A key algorithm this app does not expect from a TLS server.
    case unsupportedKeyType(String)

    /// An elliptic curve whose OID is not one of the three NIST curves TLS uses.
    case unsupportedCurve(sizeInBits: Int)

    /// `SecKeyCopyExternalRepresentation` refused the key. It does that for
    /// keys it cannot export — a key living in the Secure Enclave, most
    /// obviously, which a server certificate's never is.
    case unreadableKeyBytes
}

extension PublicKeyPin {

    /// The pin for `certificate`'s public key.
    ///
    /// ## Why this has to rebuild the `SubjectPublicKeyInfo`
    ///
    /// The value being hashed is a DER structure the certificate already
    /// contains, and there is no API that hands it back. `SecCertificateCopyKey`
    /// gives a `SecKey`; `SecKeyCopyExternalRepresentation` gives that key's
    /// *raw* bytes — a PKCS#1 `RSAPublicKey` for RSA, the uncompressed point
    /// `04 || X || Y` for EC — and neither is what a pin hashes. The
    /// `SubjectPublicKeyInfo` wraps those bytes in the algorithm identifier
    /// that says what they mean:
    ///
    /// ```
    /// SubjectPublicKeyInfo ::= SEQUENCE {
    ///     algorithm         AlgorithmIdentifier,
    ///     subjectPublicKey  BIT STRING
    /// }
    /// ```
    ///
    /// The usual implementation of this (TrustKit's, and everything that copied
    /// it) carries a table of pre-computed header blobs, one per key type and
    /// size, and prepends the matching one. That table is where the bugs are: a
    /// key size nobody tabulated silently gets no pin, and the blobs are opaque
    /// hex nobody can check by reading. Encoding the structure instead costs
    /// thirty lines, handles a size nobody anticipated, and is checkable —
    /// `PublicKeyPinTests` compares the result against `openssl`'s own
    /// `SubjectPublicKeyInfo` for three keys across both algorithms.
    package init(pinning certificate: SecCertificate) throws(PublicKeyPinError) {
        guard let key = SecCertificateCopyKey(certificate) else {
            throw PublicKeyPinError.noPublicKey
        }
        guard let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
              let keyType = attributes[kSecAttrKeyType] as? String,
              let sizeInBits = attributes[kSecAttrKeySizeInBits] as? Int
        else {
            throw PublicKeyPinError.unreadableKeyAttributes
        }
        guard let rawKey = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            throw PublicKeyPinError.unreadableKeyBytes
        }

        let algorithm = try Self.algorithmIdentifier(keyType: keyType, sizeInBits: sizeInBits)
        self.init(hashing: DER.sequence([algorithm, DER.bitString(rawKey)]))
    }

    /// The `AlgorithmIdentifier` for a key, already DER-encoded.
    ///
    /// RSA's is the `rsaEncryption` OID and an explicit NULL — the parameters
    /// field is absent-as-NULL rather than omitted, which RFC 3279 requires and
    /// which is the difference between a pin that matches `openssl` and one
    /// that is two bytes short of it. EC's is the `id-ecPublicKey` OID and the
    /// curve's own OID, so the curve has to be identified; the key size is the
    /// only thing the Security framework will say about it, and for the three
    /// curves TLS uses it identifies them uniquely.
    private static func algorithmIdentifier(
        keyType: String,
        sizeInBits: Int
    ) throws(PublicKeyPinError) -> Data {
        // Bound to locals rather than written into the `case` patterns: a
        // pattern of the form `expression as Type` is a type-casting pattern,
        // not an expression compared with `==`, so `case kSecAttrKeyTypeRSA as
        // String` would be asking a different question than it appears to.
        let rsa = kSecAttrKeyTypeRSA as String
        let ellipticCurve = kSecAttrKeyTypeECSECPrimeRandom as String

        switch keyType {
        case rsa:
            return DER.sequence([DER.oidRSAEncryption, DER.null])
        case ellipticCurve:
            let curve: Data
            switch sizeInBits {
            case 256: curve = DER.oidPrime256v1
            case 384: curve = DER.oidSecp384r1
            case 521: curve = DER.oidSecp521r1
            default: throw PublicKeyPinError.unsupportedCurve(sizeInBits: sizeInBits)
            }
            return DER.sequence([DER.oidECPublicKey, curve])
        default:
            throw PublicKeyPinError.unsupportedKeyType(keyType)
        }
    }
}

// MARK: - Just enough DER to build a SubjectPublicKeyInfo

/// Just the DER a `SubjectPublicKeyInfo` needs, and nothing else.
///
/// Not a general encoder and not a parser: this writes two SEQUENCEs, a BIT
/// STRING, a NULL and five constant OIDs, which is the whole of what pinning
/// requires.
/// Anything more would be a second ASN.1 implementation in an app that has no
/// other use for one.
private enum DER {

    /// Object identifiers, as complete tag-length-value triples rather than as
    /// bare contents, because each one is only ever emitted whole.
    ///
    /// * `oidRSAEncryption` — 1.2.840.113549.1.1.1
    /// * `oidECPublicKey` — 1.2.840.10045.2.1
    /// * `oidPrime256v1` — 1.2.840.10045.3.1.7, NIST P-256
    /// * `oidSecp384r1` — 1.3.132.0.34, NIST P-384
    /// * `oidSecp521r1` — 1.3.132.0.35, NIST P-521
    static let oidRSAEncryption = Data([0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
    static let oidECPublicKey = Data([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
    static let oidPrime256v1 = Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
    static let oidSecp384r1 = Data([0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22])
    static let oidSecp521r1 = Data([0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x23])

    /// ASN.1 NULL: the RSA algorithm identifier's parameters.
    static let null = Data([0x05, 0x00])

    /// `SEQUENCE { contents… }`.
    static func sequence(_ contents: [Data]) -> Data {
        tagged(0x30, contents.reduce(into: Data()) { $0 += $1 })
    }

    /// `BIT STRING { bytes }`, with the leading octet that says how many bits
    /// of the last byte are padding. A public key is always a whole number of
    /// bytes, so that octet is always zero — but it is part of the encoding and
    /// omitting it shifts every byte of the hash.
    static func bitString(_ bytes: Data) -> Data {
        tagged(0x03, Data([0x00]) + bytes)
    }

    /// Tag, length, value — with the length in DER's definite long form once it
    /// no longer fits in seven bits. A 2048-bit RSA key's `SubjectPublicKeyInfo`
    /// is 294 bytes, so the long form is not an edge case here; it is the
    /// common path for every RSA key and the uncommon one for every EC key.
    private static func tagged(_ tag: UInt8, _ contents: Data) -> Data {
        var out = Data([tag])
        let length = contents.count
        if length < 0x80 {
            out.append(UInt8(length))
        } else {
            var bigEndian = Data()
            var remaining = length
            while remaining > 0 {
                bigEndian.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            }
            out.append(0x80 | UInt8(bigEndian.count))
            out += bigEndian
        }
        return out + contents
    }
}
