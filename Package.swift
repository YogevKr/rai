// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "corral",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "corral", targets: ["CorralApp"]),
        .executable(name: "corral-probe", targets: ["CorralProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.15.0"),
    ],
    targets: [
        .target(name: "CorralCore"),
        .executableTarget(
            name: "CorralApp",
            dependencies: [
                "CorralCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .executableTarget(
            name: "CorralProbe",
            dependencies: ["CorralCore"]
        ),
    ]
)
