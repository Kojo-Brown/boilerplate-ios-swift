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
    // Phase 10 item 7. Required the moment a target carries a String Catalog,
    // and it is also the answer to "what does an untranslated key fall back
    // to": `en`, from the catalog, rather than the key itself.
    defaultLocalization: "en",
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
            // Each target carries its own catalog, because `Bundle.module` is
            // per-target: a string declared here and looked up from `Features`
            // would miss. See `docs/localisation.md`.
            resources: [
                .process("Resources"),
            ],
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
            resources: [
                .process("Resources"),
            ],
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
            resources: [
                .process("Resources"),
            ],
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
            // Phase 11 item 6. This target carried no resources until the
            // privacy manifest arrived. It has no String Catalog — the
            // composition root renders no text — so `Resources` here holds
            // exactly one file. See `docs/privacy-manifest.md`.
            resources: [
                .process("Resources"),
            ],
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

        // Phase 12 item 3: the snapshot diff gate.
        //
        // Its own target rather than more files in `ViewModelTests`, because
        // the two are run differently and for different reasons. The suite
        // above is run on whatever simulator the runner image happens to carry
        // the newest runtime for; a golden image is a picture taken by one
        // renderer on one OS version, so the gate gets its own CI job that
        // prefers the runtime the goldens were recorded on and says so when it
        // cannot have it. `-skip-testing:SnapshotTests` in the main job and
        // `-only-testing:SnapshotTests` in the gate's is what splits them, and
        // that needs a target name to point at.
        //
        // `exclude:` is not optional here. `__Snapshots__` holds PNGs inside
        // the target's own directory, and SwiftPM warns about every file in a
        // target it has not been told what to do with. They are not resources:
        // nothing in the bundle reads them. The suite reads them from the
        // source tree through `#filePath`, which is also what lets the record
        // lane write a file somebody can commit.
        .testTarget(
            name: "SnapshotTests",
            dependencies: ["Core", "Features"],
            path: "Tests/SnapshotTests",
            exclude: ["__Snapshots__"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
