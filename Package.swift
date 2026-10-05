// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FoundationModelServer",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "FoundationModelServer",
            path: "Sources/FoundationModelServer"
        )
    ]
)
