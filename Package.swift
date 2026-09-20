// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "JXCode",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JXCodeCore", targets: ["JXCodeCore"]),
        // Deliberately NOT named "JXCode".
        //
        // APFS is case-insensitive by default, so a product called `JXCode`
        // and a product called `jxcode` resolve to the same path in `.build/`.
        // The GUI app won that collision on every build and overwrote the CLI
        // binary — so `jxcode serve`, `jxcode prove`, `jxcode doctor` all
        // silently launched the app instead, which sits in
        // `-[NSApplication run]` forever and prints nothing. Every one of them
        // looked like a hang. The bundle script renames it to `JXCode` when it
        // assembles the .app, so nothing else has to know.
        .executable(name: "JXCodeApp", targets: ["JXCodeApp"]),
        .executable(name: "jxcode", targets: ["jxcode"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
    ],
    targets: [
        .target(name: "JXCodeCore"),

        .executableTarget(
            name: "JXCodeApp",
            dependencies: [
                "JXCodeCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),

        .executableTarget(
            name: "jxcode",
            dependencies: ["JXCodeCore"]
        ),

        .testTarget(
            name: "JXCodeCoreTests",
            dependencies: ["JXCodeCore"]
        ),
    ]
)
