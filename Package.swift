// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SwiftixDistribution",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        // SwiftixDistribution is a distribution build repository, not a runtime
        // dependency. Local development and CI check out the toolchain beside it;
        // the builder also consumes ../coreutils/Artifacts directly.
        .package(path: "../Swiftix"),
    ],
    targets: [
        .executableTarget(
            name: "SwiftixDistributionBuilder",
            dependencies: [
                .product(name: "Swiftix", package: "Swiftix"),
                .product(name: "SwiftixImage", package: "Swiftix"),
                .product(name: "SwiftixPackages", package: "Swiftix"),
            ]
        ),
        .testTarget(
            name: "SwiftixDistributionTests",
            dependencies: [
                .product(name: "Swiftix", package: "Swiftix"),
                .product(name: "SwiftixGo", package: "Swiftix"),
                .product(name: "SwiftixImage", package: "Swiftix"),
                .product(name: "SwiftixPackages", package: "Swiftix"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
