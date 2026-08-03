// swift-tools-version: 5.9

// App Playground manifest — this is what lets the app be built and run on an
// iPad itself, in Swift Playgrounds, with no Mac and no Xcode.
//
// Everything the app needs lives inside this folder, on purpose. SwiftPM
// refuses target paths that escape the package root, and Swift Playgrounds
// sandboxes access to the folder you opened, so a manifest reaching out to
// ../Sources would fail twice over. The repository's root Package.swift and
// the Xcode project both point *in* here instead, which keeps one copy of
// every file rather than a copy per build system.
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
    targets: [
        .executableTarget(
            name: "KTVApp",
            dependencies: ["KaraokeKit"],
            path: "App"
        ),
        .target(
            name: "KaraokeKit",
            path: "KaraokeKit"
        )
    ]
)
