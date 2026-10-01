import Foundation

/// `Features`' resource bundle, named so that something outside it can read it.
///
/// In `Shared` rather than in a directory of its own, because a directory
/// directly under `Sources/Features` is a feature as far as
/// `Tools/assert-module-boundaries.py` is concerned, and this is not a feature.
///
/// See `CoreResourceBundle` for why each target exposes its own rather than
/// every test writing `Bundle.module`, and `docs/privacy-manifest.md` for what
/// reads the manifest this bundle carries.
package enum FeatureResourceBundle {

    /// The bundle holding `Features`' String Catalog and its privacy manifest.
    package static var bundle: Bundle { Bundle.module }
}
