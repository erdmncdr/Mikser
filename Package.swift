// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mikser",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "Mikser",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Mikser",
            // Swift 5 language mode: the v6 mode built cleanly against Swift 6.3
            // locally but failed on the macos-15 runner's older toolchain, and CI
            // green matters more than compiler-enforced isolation here. Every
            // warning v6 surfaced has been fixed regardless, so switching the mode
            // back on once the runner's Xcode is new enough should be a one-liner.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        )
    ]
)
