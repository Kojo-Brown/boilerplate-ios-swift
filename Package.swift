// swift-tools-version: 6.0
import PackageDescription

// Phase 8 item 7: one target became four.
//
// Everything below `App` used to compile as a single module called
// `BoilerplateiOSSwift`, so "layer" meant "directory name" and nothing enforced
// it. A view could construct a `URLSession` task, a transport type could name a
// screen's model, and both compiled — which is how two edges ended up pointing
// the wrong way without anyone noticing (see `docs/modularisation.md`).
//
// The graph is a straight line and is meant to stay one:
//
//     Core  <-  Networking  <-  Features  <-  BoilerplateiOSSwift
//       ^-----------------------------------------/
//
// `Core` has no in-package dependency at all; `BoilerplateiOSSwift` is the
// composition root and the only target allowed to see all three. There is no
// edge between two features, and none from `Networking` or `Core` upward.
//
// `Tools/assert-module-boundaries.py` reads this file and every `import` in
// `Sources/`, and fails on any edge that is not declared here — because
// `.target(dependencies:)` alone cannot say "these two must never meet": adding
// a dependency is a one-line change nobody reviews, and a layering violation
// that compiles is one nobody sees. It runs in the lint job, where it needs no
// toolchain and no simulator.
let package = Package(
    name: "boilerplate-ios-swift",
    platforms: [.iOS(.v17)],
    products: [
        .library(
            name: "BoilerplateiOSSwift",
            targets: ["BoilerplateiOSSwift", "Core", "Networking", "Features"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/google/GoogleSignIn-iOS",
            from: "7.0.0"
        ),
        // There was a second dependency here: a community mirror republishing Google's
        // ML Kit xcframeworks, used by TextRecognitionService. It is gone because ML Kit
        // for iOS ships no arm64 simulator slice — the mirror's own README says it builds
        // "arm64 for iphoneos and x86_64 for iphonesimulator only" — so the test bundle
        // could not link on any Apple Silicon Mac or CI runner, and forcing the package to
        // x86_64 under Rosetta linked but aborted on launch. Text recognition now runs on
        // Apple's Vision framework, which this package already used for barcode scanning
        // and which needs no dependency at all. See TextRecognitionService.swift.
    ],
    targets: [
        // Foundation: domain models, the error vocabulary, concurrency
        // primitives, persistence, Keychain and biometrics, theming, navigation
        // routes, and the unidirectional-data-flow contract. Nothing in here
        // knows that the app has a server or a screen.
        .target(
            name: "Core",
            path: "Sources/Core",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),

        // Everything that reaches the API, and the policies layered over it:
        // the client and its endpoints, the token store, the repository
        // decorator chain, and the sync strategies that decide whether a read
        // is answered from the network or from disk.
        .target(
            name: "Networking",
            dependencies: ["Core"],
            path: "Sources/Networking",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),

        // The screens, their view models, their feature services, and the
        // design-system components they share. A feature reaches sideways to
        // `Shared` and downward to `Core` and `Networking`; the boundary check
        // is what keeps it from reaching sideways to another feature.
        .target(
            name: "Features",
            dependencies: [
                "Core",
                "Networking",
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
                .product(name: "GoogleSignInSwift", package: "GoogleSignIn-iOS"),
            ],
            path: "Sources/Features",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),

        // The composition root: `@main`, the navigation host, `AppContainer`,
        // and the one subscriber to the session events. It is the only target
        // that names a concrete implementation of anything, which is what lets
        // every target below it be built and tested without it.
        .target(
            name: "BoilerplateiOSSwift",
            dependencies: ["Core", "Networking", "Features"],
            path: "Sources/App",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),

        .testTarget(
            name: "ViewModelTests",
            dependencies: ["BoilerplateiOSSwift", "Core", "Networking", "Features"],
            path: "Tests/ViewModelTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
