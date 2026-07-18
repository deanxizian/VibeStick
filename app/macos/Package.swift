// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VibeStickSetup",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "VibeStickSetup", targets: ["VibeStickSetup"]),
    ],
    targets: [
        .target(
            name: "VibeStickProcessLauncher",
            path: "Sources/VibeStickProcessLauncher",
            publicHeadersPath: "include"
        ),
        .target(
            name: "VibeStickSetupCore",
            path: "Sources/VibeStickSetupCore"
        ),
        .target(
            name: "VibeStickSetupPlatform",
            dependencies: ["VibeStickSetupCore", "VibeStickProcessLauncher"],
            path: "Sources/VibeStickSetupPlatform",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "VibeStickSetup",
            dependencies: ["VibeStickSetupCore", "VibeStickSetupPlatform"],
            path: "Sources/VibeStickSetup"
        ),
        .testTarget(
            name: "VibeStickSetupCoreTests",
            dependencies: ["VibeStickSetupCore"],
            path: "Tests/VibeStickSetupCoreTests"
        ),
        .testTarget(
            name: "VibeStickSetupPlatformTests",
            dependencies: ["VibeStickSetupCore", "VibeStickSetupPlatform"],
            path: "Tests/VibeStickSetupPlatformTests"
        ),
    ]
)
