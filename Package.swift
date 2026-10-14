// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioRouter",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "AudioRouter", targets: ["AudioRouter"])],
    targets: [
        .executableTarget(name: "AudioRouter"),
    ]
)
