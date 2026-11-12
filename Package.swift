// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SimpleFileSync",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SimpleFileSync",
            path: "Sources/SimpleFileSync"
        )
    ]
)
