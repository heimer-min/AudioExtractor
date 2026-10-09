// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AudioExtractor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AudioExtractor", targets: ["AudioExtractor"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AudioExtractor",
            dependencies: [],
            path: "Sources"
        )
    ]
)
