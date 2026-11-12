// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScriptoriKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ScriptoriKit", targets: ["ScriptoriKit"]),
    ],
    targets: [
        .target(
            name: "ScriptoriKit",
            resources: [
                .process("Resources/Books.json"),
                .copy("Resources/Bible"),
                .copy("Resources/Guides"),
            ]
        ),
        .testTarget(
            name: "ScriptoriKitTests",
            dependencies: ["ScriptoriKit"]
        ),
    ]
)
