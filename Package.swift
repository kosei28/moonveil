// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "netafuri",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "netafuri",
            path: "Sources"
        )
    ]
)
