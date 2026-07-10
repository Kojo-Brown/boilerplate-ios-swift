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
