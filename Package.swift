// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpenKVM",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "OpenKVM",
            path: "Sources/OpenKVM",
            resources: [.process("../../Resources")],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Cocoa"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)