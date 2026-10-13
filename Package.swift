// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DevSweep",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DevSweep", path: "Sources/DevSweep")
    ]
)
