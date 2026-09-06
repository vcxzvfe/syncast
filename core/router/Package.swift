// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SyncCastRouter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SyncCastRouter", targets: ["SyncCastRouter"]),
        .executable(
            name: "SyncCastDDCProbe",
            targets: ["SyncCastDDCProbe"]
        ),
        .executable(
            name: "SyncCastSystemSinkProbe",
            targets: ["SyncCastSystemSinkProbe"]
        ),
        .executable(
            name: "SyncCastLanLinkProbe",
            targets: ["SyncCastLanLinkProbe"]
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
            name: "SyncCastDDCProbe",
            dependencies: ["SyncCastRouter"],
            path: "Sources/SyncCastDDCProbe"
        ),
        .executableTarget(
            name: "SyncCastSystemSinkProbe",
            dependencies: ["SyncCastRouter"],
            path: "Sources/SyncCastSystemSinkProbe"
        ),
        .executableTarget(
            name: "SyncCastLanLinkProbe",
            dependencies: ["SyncCastRouter"],
            path: "Sources/SyncCastLanLinkProbe"
        ),
        .testTarget(
            name: "SyncCastRouterTests",
            dependencies: ["SyncCastRouter"],
            path: "Tests/SyncCastRouterTests"
        ),
    ]
)
