// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "GianCore",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "GianCore", targets: ["GianCore"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(name: "GianCore", dependencies: ["CSQLite"], path: "Sources/GianCore"),
        .testTarget(name: "GianCoreTests", dependencies: ["GianCore", "CSQLite"], path: "Tests/GianCoreTests"),
    ]
)
