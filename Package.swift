// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "rai",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "rai", targets: ["RaiApp"]),
        .executable(name: "rai-probe", targets: ["RaiProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.15.0"),
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
    ]
)
