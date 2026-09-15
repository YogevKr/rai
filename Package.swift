// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "rai",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "RaiCore", targets: ["RaiCore"]),
        .executable(name: "rai", targets: ["RaiApp"]),
        .executable(name: "rai-updater", targets: ["RaiUpdateHelper"]),
        .executable(name: "rai-probe", targets: ["RaiProbe"]),
        .executable(name: "rai-bench", targets: ["RaiBench"]),
    ],
    dependencies: [
        // Fork of SwiftTerm 2.x (branch rai-v2, upstream base 233c6ba). rai's
        // patches on top of upstream: host read APIs (cursorPosition,
        // terminalModeFlags, getText, snapshot mode flags), selection
        // embedding (getSelectionRange/setSelectionRange, cellPosition,
        // cancelSelectionAutoScroll, bottom-edge auto-scroll fix), the iOS
        // pinned grid + live follow, a checked-in build-info/terminfo pair
        // instead of the build-tool plugin (multi-arch builds), and no
        // Embedded experimental-feature setting (Xcode 26.0 link failure).
        .package(
            url: "https://github.com/YogevKr/SwiftTerm.git",
            revision: "5ab7f43"
        ),
    ],
    targets: [
        .target(name: "RaiCore"),
        .executableTarget(
            name: "RaiApp",
            dependencies: [
                "RaiCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .executableTarget(
            name: "RaiUpdateHelper",
            dependencies: ["RaiCore"]
        ),
        .executableTarget(
            name: "RaiProbe",
            dependencies: ["RaiCore"]
        ),
        // Renderer A/B harness. Not shipped in the app bundle.
        .executableTarget(
            name: "RaiBench",
            dependencies: [
                "RaiCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(
            name: "RaiCoreTests",
            dependencies: ["RaiCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "RaiAppTests",
            dependencies: ["RaiApp", "RaiCore"]
        ),
    ]
)
