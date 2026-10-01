import Foundation
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

// MARK: - Privacy manifests

/// Phase 11 item 6.
///
/// `Tools/assert-privacy-manifest.py` reads the manifests as files on disk and
/// checks each one against the source beside it. It cannot check the one thing a
/// manifest has to be in order to mean anything, which is **inside a bundle**:
/// Xcode builds the privacy report by reading the manifests out of the bundles
/// an app embeds, and whether `PrivacyInfo.xcprivacy` got into one is a
/// `Package.swift` fact rather than a property of the file. A manifest with no
/// `resources:` rule behind it is a correct document that ships nowhere — it
/// passes the audit, it compiles, every test goes green, and the privacy report
/// is assembled without it.
///
/// So this suite goes through `Bundle`, once per target, and asserts the parsed
/// contents rather than only that something was found: a manifest that is
/// present and says the wrong thing is the failure that reaches the App Store.
///
/// What each declaration is, and why, is in `docs/privacy-manifest.md`.
@Suite("Privacy manifests")
struct PrivacyManifestTests {

    /// A manifest, decoded.
    ///
    /// `PropertyListDecoder` rather than `PropertyListSerialization`: the
    /// untyped form hands back `Any` and every assertion below it becomes a
    /// cast, and a cast that fails reads as "nil" rather than as the wrong
    /// shape. Unknown top-level keys are not this type's problem — `Decodable`
    /// ignores them, and the audit is what fails on one.
    struct Manifest: Decodable {
        let tracking: Bool
        let trackingDomains: [String]
        let collectedDataTypes: [CollectedDataType]
        let accessedAPITypes: [AccessedAPIType]

        enum CodingKeys: String, CodingKey {
            case tracking = "NSPrivacyTracking"
            case trackingDomains = "NSPrivacyTrackingDomains"
            case collectedDataTypes = "NSPrivacyCollectedDataTypes"
            case accessedAPITypes = "NSPrivacyAccessedAPITypes"
        }
    }

    /// One row of the privacy report: what leaves the device, and what for.
    ///
    /// Every field is non-optional, which is the assertion: Apple requires all
    /// four of them, and `false` for `linked` or `tracking` is a real answer
    /// that a decode has to tell apart from an absent key.
    struct CollectedDataType: Decodable {
        let kind: String
        let linked: Bool
        let tracking: Bool
        let purposes: [String]

        enum CodingKeys: String, CodingKey {
            case kind = "NSPrivacyCollectedDataType"
            case linked = "NSPrivacyCollectedDataTypeLinked"
            case tracking = "NSPrivacyCollectedDataTypeTracking"
            case purposes = "NSPrivacyCollectedDataTypePurposes"
        }
    }

    /// One required-reason API category, with the codes justifying it.
    struct AccessedAPIType: Decodable {
        let category: String
        let reasons: [String]

        enum CodingKeys: String, CodingKey {
            case category = "NSPrivacyAccessedAPIType"
            case reasons = "NSPrivacyAccessedAPITypeReasons"
        }
    }

    /// Loads the manifest out of a *built* bundle.
    ///
    /// `url(forResource:withExtension:)` and not a path join: the layout of a
    /// SwiftPM resource bundle is not the same on a macOS test host as on an
    /// iOS simulator one, and asking the bundle is the only form right in both.
    static func manifest(in bundle: Bundle) throws -> Manifest {
        // A nil here is not a missing file: the audit reads the four manifests
        // off disk and would have failed first. It is a missing `resources:`
        // rule in `Package.swift`, which is the whole reason this suite exists.
        let url = try #require(
            bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "\(bundle.bundleURL.lastPathComponent) carries no PrivacyInfo.xcprivacy"
        )
        let data = try Data(contentsOf: url)
        return try PropertyListDecoder().decode(Manifest.self, from: data)
    }

    /// The categories a manifest declares, mapped to their reason codes.
    static func categories(of manifest: Manifest) -> [String: Set<String>] {
        Dictionary(
            manifest.accessedAPITypes.map { ($0.category, Set($0.reasons)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The data types a manifest declares.
    static func collected(of manifest: Manifest) -> Set<String> {
        Set(manifest.collectedDataTypes.map(\.kind))
    }

    // MARK: - Core

    /// `Core` is the only target reaching a required-reason API:
    /// `AppState.colorSchemePreference` and `UserDefaultsBackgroundRefreshLedger`,
    /// both app-private, which is what `CA92.1` describes.
    ///
    /// `1C8F.1` is deliberately absent — the ledger's `suiteName` is `nil` at
    /// every call site, so there is no App Group store to declare.
    @Test("Core declares app-private UserDefaults and nothing else")
    func coreManifest() throws {
        let manifest = try Self.manifest(in: CoreResourceBundle.bundle)
        #expect(Self.categories(of: manifest) == [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
        ])
        #expect(Self.collected(of: manifest).isEmpty)
    }

    // MARK: - Networking

    /// The profile `PATCH` sends the display name, and `X-Attest-Key-Id` sends
    /// the App Attest key identifier on every request the attestor can sign.
    /// `docs/privacy-manifest.md` carries the argument for declaring the second
    /// as a device identifier when the narrower reading is also defensible.
    @Test("Networking declares the name and the attestation key identifier")
    func networkingManifest() throws {
        let manifest = try Self.manifest(in: NetworkingResourceBundle.bundle)
        #expect(Self.collected(of: manifest) == [
            "NSPrivacyCollectedDataTypeName",
            "NSPrivacyCollectedDataTypeDeviceID",
        ])
        #expect(Self.categories(of: manifest).isEmpty)
        for row in manifest.collectedDataTypes {
            #expect(row.purposes == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"])
            #expect(row.linked)
            #expect(!row.tracking)
        }
    }

    // MARK: - Features

    /// `/auth/login` carries the email address and the password; `/auth/social`
    /// carries the provider's identity token and the names Apple hands back.
    ///
    /// The camera is absent on purpose: frames go to Vision on device and
    /// nothing is transmitted. What that needs is `NSCameraUsageDescription` in
    /// an `Info.plist`, a different mechanism — and a gap, recorded in
    /// `docs/privacy-manifest.md`.
    @Test("Features declares what the sign-in forms put on the wire")
    func featuresManifest() throws {
        let manifest = try Self.manifest(in: FeatureResourceBundle.bundle)
        #expect(Self.collected(of: manifest) == [
            "NSPrivacyCollectedDataTypeEmailAddress",
            "NSPrivacyCollectedDataTypeName",
        ])
        #expect(Self.categories(of: manifest).isEmpty)
    }

    // MARK: - The composition root

    /// It declares nothing, and the point of the test is that it ships a file
    /// saying so. An absent manifest and an empty one read the same way to
    /// Apple's tooling; to a reader, absent is "nobody assessed this target".
    @Test("The composition root ships a manifest that declares nothing")
    func appManifest() throws {
        let manifest = try Self.manifest(in: AppResourceBundle.bundle)
        #expect(Self.collected(of: manifest).isEmpty)
        #expect(Self.categories(of: manifest).isEmpty)
    }

    // MARK: - Across all four

    /// Nothing in this package tracks, and the domain list is the half with a
    /// runtime consequence: once the user has denied tracking, iOS refuses a
    /// connection to a domain in it. An empty list beside `NSPrivacyTracking`
    /// `== false` is the only self-consistent pair here.
    ///
    /// Not a parameterised test over the four bundles, because `@Test(arguments:)`
    /// needs its arguments to be `Sendable` and `Bundle` is not.
    @Test("No manifest claims tracking")
    func noManifestClaimsTracking() throws {
        let bundles = [
            CoreResourceBundle.bundle,
            NetworkingResourceBundle.bundle,
            FeatureResourceBundle.bundle,
            AppResourceBundle.bundle,
        ]
        for bundle in bundles {
            let manifest = try Self.manifest(in: bundle)
            let name = bundle.bundleURL.lastPathComponent
            #expect(!manifest.tracking, "\(name) claims tracking")
            #expect(manifest.trackingDomains.isEmpty, "\(name) lists tracking domains")
        }
    }
}
