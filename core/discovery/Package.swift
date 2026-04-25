// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SyncCastDiscovery",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SyncCastDiscovery", targets: ["SyncCastDiscovery"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SyncCastDiscovery",
            path: "Sources/SyncCastDiscovery"
        ),
        .testTarget(
            name: "SyncCastDiscoveryTests",
            dependencies: ["SyncCastDiscovery"],
            path: "Tests/SyncCastDiscoveryTests"
        ),
    ]
)
