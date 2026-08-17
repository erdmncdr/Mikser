// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mikser",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Mikser",
            path: "Sources/Mikser",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
