import Foundation

/// `Core`'s resource bundle, named so that something outside `Core` can read it.
///
/// Phase 11 item 6. `Bundle.module` is generated once per target, is `internal`
/// to the target it is generated for, and is spelled identically in all four of
/// them — so a test that `@testable import`s two of these targets cannot write
/// `Bundle.module` at all, and a test that imports one gets that target's bundle
/// whatever it meant. Each target that ships resources exposes its own under a
/// name of its own instead.
///
/// The privacy manifest is why this exists. `PrivacyInfo.xcprivacy` is a file
/// that has to be *inside a bundle* to mean anything — Xcode builds the privacy
/// report by reading the manifests out of the bundles an app embeds — and
/// whether it got there is a `Package.swift` fact. Reading the file on disk, as
/// `Tools/assert-privacy-manifest.py` does, cannot confirm it: a manifest with
/// no `resources:` rule behind it is a correct document that ships nowhere, and
/// nothing about that is visible in a diff, a compile or a test run that does
/// not go looking. `PrivacyManifestTests` goes looking, through this.
///
/// See `docs/privacy-manifest.md`.
package enum CoreResourceBundle {

    /// The bundle holding `Core`'s String Catalog and its privacy manifest.
    ///
    /// Computed rather than a `static let`, because a stored static of a
    /// reference type is a global whose `Sendable` conformance Swift 6 mode
    /// checks, and `Bundle.module` is already a cached lazy global — a second
    /// one would add storage without adding a guarantee.
    package static var bundle: Bundle { Bundle.module }
}
