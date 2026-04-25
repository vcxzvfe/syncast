// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SyncCastRouter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SyncCastRouter", targets: ["SyncCastRouter"]),
    ],
    dependencies: [
        .package(path: "../discovery"),
    ],
    targets: [
        .target(
            name: "SyncCastAtomic",
            path: "Sources/SyncCastAtomic",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SyncCastRouter",
            dependencies: [
                .product(name: "SyncCastDiscovery", package: "discovery"),
                "SyncCastAtomic",
            ],
            path: "Sources/SyncCastRouter"
        ),
        .testTarget(
            name: "SyncCastRouterTests",
            dependencies: ["SyncCastRouter"],
            path: "Tests/SyncCastRouterTests"
        ),
    ]
)
