// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "syncast-discover",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../core/discovery"),
    ],
    targets: [
        .executableTarget(
            name: "syncast-discover",
            dependencies: [
                .product(name: "SyncCastDiscovery", package: "discovery"),
            ],
            path: "Sources/syncast-discover"
        ),
    ]
)
