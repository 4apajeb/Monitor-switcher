// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MonitorSwitcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MonitorSwitcher",
            path: "Sources/MonitorSwitcher",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
