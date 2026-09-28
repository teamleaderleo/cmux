// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMarkdownUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxMarkdownUI", targets: ["CmuxMarkdownUI"]),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxSettings"),
    ],
    targets: [
        .target(
            name: "CmuxMarkdownUI",
            dependencies: [.product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxSettings", package: "CmuxSettings")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMarkdownUITests",
            dependencies: ["CmuxMarkdownUI"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
