// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "jiantieban",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "Core",
            path: "Sources/Core"
        ),
        .target(
            name: "PastebackPlatform",
            dependencies: ["Core"],
            path: "Sources/PastebackPlatform"
        ),
        .target(
            name: "PanelLayout",
            path: "Sources/PanelLayout"
        ),
        .executableTarget(
            name: "jiantieban",
            dependencies: ["Core", "PastebackPlatform", "PanelLayout"],
            path: "Sources/jiantieban"
        ),
        .executableTarget(
            name: "jiantieban-tests",
            dependencies: ["Core", "PastebackPlatform", "PanelLayout"],
            path: "Sources/jiantieban-tests"
        ),
    ]
)
