// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "eyeOS",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "eyeOS", path: "Sources/eyeOS")
    ]
)
