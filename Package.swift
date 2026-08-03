// swift-tools-version: 5.9
import PackageDescription

// The library sources live inside KTV.swiftpm/ rather than in Sources/.
//
// That looks backwards, but it's forced: Swift Playgrounds can only see the
// folder you open, and SwiftPM rejects target paths that escape the package
// root — so an app playground cannot reach out to a sibling Sources/ directory.
// Putting the sources where the most constrained build system can reach them,
// and pointing the less constrained ones in, keeps a single copy of every file.
//
// This package builds and tests KaraokeKit on macOS and Linux. KTV.swiftpm
// builds the app on an iPad. App/project.yml builds it in Xcode. All three read
// the same files.
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
            path: "KTV.swiftpm/KaraokeKit",
            swiftSettings: [
                .unsafeFlags(["-Ounchecked"], .when(configuration: .release))
            ]
        ),
        .testTarget(
            name: "KaraokeKitTests",
            dependencies: ["KaraokeKit"],
            path: "Tests/KaraokeKitTests"
        )
    ]
)
