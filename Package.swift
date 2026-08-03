// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "boilerplate-ios-swift",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "BoilerplateiOSSwift", targets: ["BoilerplateiOSSwift"]),
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
        .target(
            name: "BoilerplateiOSSwift",
            dependencies: [
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
                .product(name: "GoogleSignInSwift", package: "GoogleSignIn-iOS"),
            ],
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "ViewModelTests",
            dependencies: ["BoilerplateiOSSwift"],
            path: "Tests/ViewModelTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
