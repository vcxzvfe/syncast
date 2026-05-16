// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SyncCastRouter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SyncCastRouter", targets: ["SyncCastRouter"]),
        .executable(
            name: "SyncCastRouterTimingCheck",
            targets: ["SyncCastRouterTimingCheck"]
        ),
        .executable(
            name: "SyncCastPassiveHeadless",
            targets: ["SyncCastPassiveHeadless"]
        ),
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
        .executableTarget(
            name: "SyncCastRouterTimingCheck",
            dependencies: ["SyncCastRouter"],
            path: "Sources/SyncCastRouterTimingCheck"
        ),
        .executableTarget(
            name: "SyncCastPassiveHeadless",
            dependencies: [
                "SyncCastRouter",
                .product(name: "SyncCastDiscovery", package: "discovery"),
            ],
            path: "Sources/SyncCastPassiveHeadless"
        ),
        .testTarget(
            name: "SyncCastRouterTests",
            dependencies: ["SyncCastRouter"],
            path: "Tests/SyncCastRouterTests"
        ),
    ]
)
