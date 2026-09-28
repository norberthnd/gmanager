// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GhostKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GhostKit", targets: ["GhostKit"]),
    ],
    dependencies: [
        // Mirrors CryptoKit's API; on Apple platforms it re-exports CryptoKit.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "GhostKit",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(
            name: "GhostKitTests",
            dependencies: ["GhostKit"]
        ),
    ]
)
