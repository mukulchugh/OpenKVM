// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeySwitch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "KeySwitch",
            path: "Sources/KeySwitch",
            resources: [.process("../../Resources")],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Cocoa"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ]
)