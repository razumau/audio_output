// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AudioRouter",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "AudioRouter",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
