// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "screenlink",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "screenlink",
            path: "Sources/screenlink",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
