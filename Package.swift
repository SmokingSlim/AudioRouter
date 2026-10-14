// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SoundTool",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "SoundTool", targets: ["SoundTool"])],
    targets: [
        .executableTarget(name: "SoundTool"),
    ]
)
