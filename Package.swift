// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Caret",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Caret",
            path: "Sources/Caret",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
