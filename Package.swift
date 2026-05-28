// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "atst",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "atst", targets: ["atst"])
    ],
    targets: [
        .executableTarget(
            name: "atst",
            path: "Sources/atst"
        )
    ]
)
