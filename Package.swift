// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "boilerplate-ios-swift",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "BoilerplateiOSSwift", targets: ["BoilerplateiOSSwift"]),
    ],
    targets: [
        .target(
            name: "BoilerplateiOSSwift",
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
