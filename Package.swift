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
        // Google ships ML Kit for iOS through CocoaPods only; there is no first-party
        // Swift Package. The URL this manifest used to name — google-mlkit/ml-kit-ios —
        // does not exist on GitHub at any version, so the graph could never resolve.
        // This is the community mirror the iOS ecosystem uses: it republishes Google's
        // own xcframeworks as checksummed binary targets. Pinned exactly rather than by
        // range, because on a binary mirror a floating version swaps the shipped
        // framework with no source diff to review.
        .package(
            url: "https://github.com/d-date/google-mlkit-swiftpm",
            exact: "9.0.0"
        ),
    ],
    targets: [
        .target(
            name: "BoilerplateiOSSwift",
            dependencies: [
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
                .product(name: "GoogleSignInSwift", package: "GoogleSignIn-iOS"),
                // MLKitVision and MLImage are targets bundled into this product, not
                // products in their own right, so `import MLKitVision` resolves through
                // this single dependency.
                .product(name: "MLKitTextRecognition", package: "google-mlkit-swiftpm"),
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
