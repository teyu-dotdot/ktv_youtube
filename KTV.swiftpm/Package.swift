// swift-tools-version: 5.9

// App Playground manifest — this is what lets the app be built and run on an
// iPad itself, in Swift Playgrounds, with no Mac and no Xcode.
//
// The app sources live in ../App/KTVYouTube and are referenced in place rather
// than duplicated, so there is only ever one copy to edit. KaraokeKit comes
// from the repository root, which is a plain Swift package.
//
// See ../docs/BUILDING-ON-IPAD.md for what does and doesn't work this way.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "KTV",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "KTV",
            targets: ["KTVApp"],
            bundleIdentifier: "com.example.ktvyoutube",
            teamIdentifier: "",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .music),
            accentColor: .presetColor(.purple),
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ]
        )
    ],
    dependencies: [
        .package(name: "KaraokeKit", path: "..")
    ],
    targets: [
        .executableTarget(
            name: "KTVApp",
            dependencies: [
                .product(name: "KaraokeKit", package: "KaraokeKit")
            ],
            path: "../App/KTVYouTube",
            exclude: ["Info.plist"]
        )
    ]
)
