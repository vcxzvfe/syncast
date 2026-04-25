// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SyncCastMenuBar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../core/discovery"),
        .package(path: "../../core/router"),
    ],
    targets: [
        .executableTarget(
            name: "SyncCastMenuBar",
            dependencies: [
                .product(name: "SyncCastDiscovery", package: "discovery"),
                .product(name: "SyncCastRouter", package: "router"),
            ],
            path: "Sources/SyncCastMenuBar"
        ),
    ]
)
