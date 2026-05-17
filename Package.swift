// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "tuist-to-bazel",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "tuist-to-bazel", targets: ["TuistToBazelCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "TuistToBazelCLI",
            dependencies: [
                "TuistToBazelCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "TuistToBazelCore"),
        .testTarget(
            name: "TuistToBazelCoreTests",
            dependencies: ["TuistToBazelCore"]
        ),
    ]
)
