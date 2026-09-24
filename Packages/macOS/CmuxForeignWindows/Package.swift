// swift-tools-version: 6.0

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "CmuxForeignWindows",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxForeignWindows", targets: ["CmuxForeignWindows"]),
        .executable(name: "ForeignWindowLab", targets: ["ForeignWindowLab"]),
    ],
    targets: [
        .target(
            name: "CmuxForeignWindows",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "ForeignWindowLab",
            dependencies: ["CmuxForeignWindows"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CmuxForeignWindowsTests",
            dependencies: ["CmuxForeignWindows"],
            swiftSettings: swiftSettings
        ),
    ]
)
