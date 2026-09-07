// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexUsageWidgetMVP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CodexUsageCore", targets: ["CodexUsageCore"]),
        .executable(name: "CodexUsageMenuBar", targets: ["CodexUsageMenuBar"]),
        .executable(name: "CodexUsageCoreSmoke", targets: ["CodexUsageCoreSmoke"])
    ],
    targets: [
        .target(name: "CodexUsageCore"),
        .executableTarget(
            name: "CodexUsageMenuBar",
            dependencies: ["CodexUsageCore"]
        ),
        .executableTarget(
            name: "CodexUsageCoreSmoke",
            dependencies: ["CodexUsageCore"]
        )
    ]
)
