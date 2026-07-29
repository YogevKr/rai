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
        .executable(name: "rai-probe", targets: ["RaiProbe"]),
    ],
    dependencies: [
        // Fork of SwiftTerm 1.15.0 (branch rai-selection-autoscroll) adding
        // public getSelectionRange/setSelectionRange + a pointer-based edge
        // auto-scroll fix (remote-scrollback selection engine), and
        // pinGridSize (iOS) so the phone mirrors a pane's full grid and
        // scrolls a viewport over it instead of clipping.
        .package(
            url: "https://github.com/YogevKr/SwiftTerm.git",
            revision: "599ddab6e46ccabfb45f1bc568fa28dd44cc9e87"
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
            name: "RaiProbe",
            dependencies: ["RaiCore"]
        ),
        .testTarget(
            name: "RaiCoreTests",
            dependencies: ["RaiCore"]
        ),
        .testTarget(
            name: "RaiAppTests",
            dependencies: ["RaiApp", "RaiCore"]
        ),
    ]
)
