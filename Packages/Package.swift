// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "JXCODEPackages",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "JXCODECore", targets: ["JXCODECore"]),
        .library(name: "JXCODEChatKit", targets: ["JXCODEChatKit"]),
    ],
    targets: [
        .target(
            name: "JXCODECore",
            path: "Sources/JXCODECore"
        ),
        .target(
            name: "JXCODEChatKit",
            dependencies: ["JXCODECore"],
            path: "Sources/JXCODEChatKit",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
            ]
        ),
        .testTarget(
            name: "JXCODECoreTests",
            dependencies: ["JXCODECore"],
            path: "Tests/JXCODECoreTests"
        ),
    ]
)
