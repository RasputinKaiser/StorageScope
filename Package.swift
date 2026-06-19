// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "StorageScope",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "StorageScope", targets: ["StorageScope"]),
        .executable(name: "StorageScopeBenchmark", targets: ["StorageScopeBenchmark"]),
        .library(name: "StorageScopeCore", targets: ["StorageScopeCore"])
    ],
    targets: [
        .target(
            name: "StorageScopeCore"
        ),
        .executableTarget(
            name: "StorageScope",
            dependencies: [
                "StorageScopeCore"
            ],
            exclude: [
                "Resources"
            ]
        ),
        .executableTarget(
            name: "StorageScopeBenchmark",
            dependencies: [
                "StorageScopeCore"
            ]
        ),
        .testTarget(
            name: "StorageScopeCoreTests",
            dependencies: [
                "StorageScopeCore"
            ]
        ),
        .testTarget(
            name: "StorageScopeTests",
            dependencies: [
                "StorageScope"
            ]
        )
    ]
)
