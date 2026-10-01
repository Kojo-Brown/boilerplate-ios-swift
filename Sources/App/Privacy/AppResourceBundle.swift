import Foundation

/// The composition root's resource bundle, named so that a test can read it.
///
/// This target had no resources at all until the privacy manifest arrived, and
/// the manifest it carries declares nothing — see
/// `Sources/App/Resources/PrivacyInfo.xcprivacy` for why a target with nothing
/// to say still says it.
///
/// See `CoreResourceBundle` for why each target exposes its own rather than
/// every test writing `Bundle.module`, and `docs/privacy-manifest.md` for what
/// reads the manifest this bundle carries.
package enum AppResourceBundle {

    /// The bundle holding this target's privacy manifest, and nothing else.
    package static var bundle: Bundle { Bundle.module }
}
