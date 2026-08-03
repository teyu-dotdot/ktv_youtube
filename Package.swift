// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KaraokeKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "KaraokeKit", targets: ["KaraokeKit"])
    ],
    targets: [
        .target(
            name: "KaraokeKit",
            swiftSettings: [
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release))
            ]
        ),
        .testTarget(
            name: "KaraokeKitTests",
            dependencies: ["KaraokeKit"]
        )
    ]
)
