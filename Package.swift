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
        // Fork of migueldeicaza/SwiftTerm 1.15.0 with one fix: selection
        // auto-scroll fires at the bottom edge (upstream derived the trigger
        // from a clamped hit row, so dragging a selection to the bottom never
        // scrolled). Branch rai-selection-autoscroll; upstreaming pending.
        .package(
            url: "https://github.com/YogevKr/SwiftTerm.git",
            revision: "4240f21a1b1d601e623f8bbf238d204860d5b08d"
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
