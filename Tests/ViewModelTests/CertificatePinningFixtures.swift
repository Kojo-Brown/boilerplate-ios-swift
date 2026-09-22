import Foundation
import Security
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Networking

// MARK: - Fixtures

/// Three certificates, generated once with `openssl` and checked in.
///
/// They are a self-signed RSA-2048 root and two leaves it issued for
/// `pinned.example.com` — one on EC P-256, one on EC P-384. Between them they
/// cover both key algorithms a TLS server uses and three of the four
/// `AlgorithmIdentifier` shapes `PublicKeyPin` has to encode.
///
/// The expected pins beside them are not computed by this code. They are what
/// the standard pipeline printed for the same files:
///
/// ```
/// openssl x509 -in leaf.crt -pubkey -noout \
///   | openssl pkey -pubin -outform der \
///   | openssl dgst -sha256 -binary | base64
/// ```
///
/// That is the whole point of these three constants: they are an independent
/// implementation's answer, so a test comparing against them is evidence about
/// the DER encoding in `PublicKeyPin` rather than a restatement of it.
///
/// Nothing here is a credential. A certificate is public by construction, the
/// private keys were discarded, and no server has ever presented any of them.
enum PinningFixture {

    /// One fixture certificate: the DER it decodes from and the pin `openssl`
    /// says it has.
    struct Certificate: Sendable {
        let name: String
        let der: String
        let expectedPin: String

        /// The `SecCertificate`, built the way `SecTrust` hands one over.
        var certificate: SecCertificate {
            get throws {
                let data = try #require(Data(base64Encoded: der, options: .ignoreUnknownCharacters))
                return try #require(SecCertificateCreateWithData(nil, data as CFData))
            }
        }

        var pin: PublicKeyPin {
            get throws { try PublicKeyPin(pinning: certificate) }
        }
    }

    /// The host every fixture leaf names, in its subject and its SAN.
    static let host = "pinned.example.com"

    static let leaf = Certificate(
        name: "leaf (EC P-256)",
        der: leafDER,
        expectedPin: "KP/N9ocBRCd3lGRvW094gKTiVWspfyq16bIFHI7cFiI="
    )

    static let backup = Certificate(
        name: "backup (EC P-384)",
        der: backupDER,
        expectedPin: "2oGJGity2zAbabeato0tRuVVl+DNxbPG5MprNfj5pVs="
    )

    static let root = Certificate(
        name: "root (RSA-2048)",
        der: rootDER,
        expectedPin: "8b/BvAx9P6/bDKzwqO7hiUj5VWfIEWYS2C3tU0kCB6I="
    )

    static let all = [leaf, backup, root]

    /// A `SecTrust` over `certificates`, evaluated against nothing in
    /// particular. Every delegate test needs one, and most of them only need
    /// it to be non-nil — the verdict comes from the substituted evaluator.
    static func trust(over certificates: [SecCertificate]) throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            certificates as CFArray,
            SecPolicyCreateSSL(true, host as CFString),
            &trust
        )
        #expect(status == errSecSuccess)
        return try #require(trust)
    }

    // MARK: - The DER, base64 as `openssl x509 -outform der | base64` prints it

    static let leafDER = """
    MIICmTCCAYGgAwIBAgIUG6ePDAB6/JcdydYdTFJhwsut0LcwDQYJKoZIhvcNAQEL
    BQAwIzEhMB8GA1UEAwwYQm9pbGVycGxhdGUgVGVzdCBSb290IENBMB4XDTI2MDky
    MjIwNTcwMFoXDTI3MTAyNTIwNTcwMFowHTEbMBkGA1UEAwwScGlubmVkLmV4YW1w
    bGUuY29tMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEdiGZXcB25mQEa+aqok5/
    dnNsQXk8SrlNm/jfI6lgCbyWAtEzCHd9Q2dsJwTLoHLOSRIGb6lo6QsY0deGtV6v
    KqOBlTCBkjAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIFoDATBgNVHSUEDDAK
    BggrBgEFBQcDATAdBgNVHREEFjAUghJwaW5uZWQuZXhhbXBsZS5jb20wHQYDVR0O
    BBYEFG97tWAiiYtAKlMiStrMeP1OPxpaMB8GA1UdIwQYMBaAFMgpHokTdLTUwdjU
    AsSKqGdG5sXZMA0GCSqGSIb3DQEBCwUAA4IBAQBXzostg/1LLIHrTavq+GVlIcbR
    MVuOydK3XLwoTuos9k+e+7wvaprNYnZyMjMoBScSMzVN/uQBM4Q0HH1eiJtZwoZS
    LvoQ/BaPByEVbCUXWAsM1Okvb60ypWUBvXWeIJ/ktP6eERL0lrTf3duqlCumev56
    S8JGyeCHPyg2mXxOB37IJeOhgFYdqNm7VIHFtf26n666maJm1lBEeG/AkWhK1fjO
    0n4Nz72kUDFGBCSnlBfOGTjDXQ5N+K6XWOTDkydvHOMjkh3y+lHA8Hb3GLuE35tP
    HWC5OmMiO5u2jmnbQQdoOwFgJi8/wwJkz5NwJooCul7vdlwPIrtTPuHG7XCL
    """

    static let backupDER = """
    MIICtjCCAZ6gAwIBAgIUG6ePDAB6/JcdydYdTFJhwsut0LgwDQYJKoZIhvcNAQEL
    BQAwIzEhMB8GA1UEAwwYQm9pbGVycGxhdGUgVGVzdCBSb290IENBMB4XDTI2MDky
    MjIwNTcwMFoXDTI3MTAyNTIwNTcwMFowHTEbMBkGA1UEAwwScGlubmVkLmV4YW1w
    bGUuY29tMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEkWu0D8sRC+Ot+P/5A+oxFgk/
    V6u/KA6ttvjIlQd0JdWzHqZkBOQiekAIpBdJVpZchn/oSvJ1iUOO/N+qDUVD7ZaE
    02MaPjQMFs4AHqTAeroI7LRUaKmh8UoDfAZM7F//o4GVMIGSMAwGA1UdEwEB/wQC
    MAAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMBMB0GA1UdEQQW
    MBSCEnBpbm5lZC5leGFtcGxlLmNvbTAdBgNVHQ4EFgQU462mU1tMbNd9ms/8Vdqx
    aigjtrEwHwYDVR0jBBgwFoAUyCkeiRN0tNTB2NQCxIqoZ0bmxdkwDQYJKoZIhvcN
    AQELBQADggEBAD8PMAgmYsTcqMepMvAyo2CPsOBHpNtHWCGQtu7YOmOHZh7MW6+I
    F13P/uiCtti6UquDgsq/qf6EhHOZeaDhnEAjR6AqcY3l1tbH3mJvthGiM3bNbLfn
    WSlcAq+YfvkpmpLHs5hctjVtslCMy/2ngjCS6DqpuXbyVcH0cMKrnVADiKRgIyke
    6KIwtYRPrM8bWv7EXz2d2auS2zsm8Iz2uaA/SbNIBUmpNMWhO8UtXy5S9o3pjBl3
    FZXBGPMv0g+RlPxmmehZn4sDXwXCHKBxkfEdpLmiy744rBjJ+gPr72nSh6daFP+O
    P1bi+p6lhSKcGjeZQ7/D5WWCfT4Y2GjuMxc=
    """

    static let rootDER = """
    MIIDNzCCAh+gAwIBAgIUfiSC1TUcEVlOVHa1prRcR5PYAX4wDQYJKoZIhvcNAQEL
    BQAwIzEhMB8GA1UEAwwYQm9pbGVycGxhdGUgVGVzdCBSb290IENBMB4XDTI2MDky
    MjIwNTcwMFoXDTQ2MDkxNzIwNTcwMFowIzEhMB8GA1UEAwwYQm9pbGVycGxhdGUg
    VGVzdCBSb290IENBMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAr1qy
    DNYzbucZRnmHJ+p3/nldUAW4uauYrq3NuchStEhjJRIAfcYOTSkElEKmb2l8SplN
    PvSulgRoj3SCTxg4I4Ay6Tf1lrOJABnfT56OQSCfnC2zsYHXsuXPmv6oTugf+47b
    ASkzfwoj019hcyR/jEAQyD2ODIiZ7eZb5++p4hM5BopnCPFKf2yL96a4t7QpKdd8
    7BqHc/4xnxEe7BcXvdq09I7hXekuI7ccriiTca0aYcDIIUiSvevNBLjH+FisRoXj
    iBQU3JY409nt4T/gMgyym4okeR1TquIW2ZS4XHMr5Ds0n9d0KtLpzrwF1ZKlCwxc
    Qz3fd08dnv7Q5c7+5QIDAQABo2MwYTAdBgNVHQ4EFgQUyCkeiRN0tNTB2NQCxIqo
    Z0bmxdkwHwYDVR0jBBgwFoAUyCkeiRN0tNTB2NQCxIqoZ0bmxdkwDwYDVR0TAQH/
    BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwDQYJKoZIhvcNAQELBQADggEBADqO4Sar
    x2MZkVBYwUJjs+eWkjCo1H+en396dv8m9IfrDZFcwjbknS9Y1xbl4wH6PCoMjXM7
    PBQRIvjtr+q4qUg6XSw7NtutpknIaZIqVmkEGKoJTpelTmzMRSAG6YH8Q6zfP9i5
    gQjjg/CnWJzwn8rk/aLp1YXO+otdBoVhoFQcLzvssUCSk3grUTOqA3QIVrzfwvVl
    TVPx3wB3va032vIg9n1RB8ztilomK2Td2KcU1/Zbigm93pwBkaf4+JPR/8F+NHfh
    aBU31fJ4w5jgCZBz4rqWqFbQMyMEdFKb6j/lu+x79vn/YRLZpstv4Cc3xJtr/8GI
    kgkqCjjwJb7Dk1g=
    """
}
