import BoilerplateiOSSwift
import SwiftUI

/// The app's entry point, and the only code this target has.
///
/// Phase 12 item 4. `BoilerplateApp` carried `@main` until this item, which
/// read naturally and could never produce a bundle: the attribute synthesises
/// the `main` symbol wherever it sits, and in a SwiftPM library that symbol is
/// in a static archive with nothing installable around it. Moving it here is
/// what makes an `.app` out of the package, and it has to move rather than be
/// duplicated — two `@main` declarations linked into one binary are two
/// definitions of `_main`, which is a link error rather than a warning.
///
/// So the host owns the entry point and the app owns everything else.
/// `BoilerplateApp.main()` is `App`'s own entry point, the same call the
/// attribute would have made, which is what keeps this file from being a second
/// composition root: it builds nothing, injects nothing and decides nothing.
/// Read `Sources/App/BoilerplateApp.swift` for what actually starts.
///
/// `@MainActor` on `main()` rather than on the type: `App.main()` is
/// main-actor isolated — it installs the scene and hands control to UIKit — and
/// `@main` accepts a main-actor-isolated `main()`, which is the same shape
/// SwiftUI's own synthesised entry point has.
@main
enum HostEntryPoint {

    @MainActor
    static func main() {
        BoilerplateApp.main()
    }
}
