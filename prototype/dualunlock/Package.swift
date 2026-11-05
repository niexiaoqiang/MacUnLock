// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "dualunlock",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "dualunlock", path: "Sources/dualunlock")
    ]
)
