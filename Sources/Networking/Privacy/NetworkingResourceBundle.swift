import Foundation

/// `Networking`'s resource bundle, named so that something outside it can read it.
///
/// See `CoreResourceBundle` for why each target exposes its own rather than
/// every test writing `Bundle.module`, and `docs/privacy-manifest.md` for what
/// reads the manifest this bundle carries.
package enum NetworkingResourceBundle {

    /// The bundle holding `Networking`'s String Catalog and its privacy manifest.
    package static var bundle: Bundle { Bundle.module }
}
