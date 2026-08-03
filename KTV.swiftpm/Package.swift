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
        // Deliberately minimal. `appIcon:` and `accentColor:` are omitted
        // rather than hard-coded: the enum members available to them differ
        // between Swift Playgrounds versions, and a wrong name doesn't fail
        // gracefully — the manifest won't compile, so the whole project refuses
        // to load with an error that points at the icon rather than the cause.
        //
        // Set them in **⋯ ▸ App Settings** instead. Swift Playgrounds writes
        // the correct syntax for its own version straight back into this file.
        .iOSApplication(
            name: "KTV",
            targets: ["KTVApp"],
            bundleIdentifier: "com.example.ktvyoutube",
            displayVersion: "1.0",
            bundleVersion: "1",
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft
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
