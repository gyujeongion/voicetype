// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VoiceType",
    defaultLocalization: "ko",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VoiceType", targets: ["VoiceType"]),
        .library(name: "VoiceTypeCore", targets: ["VoiceTypeCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "VoiceTypeCore",
            path: "Sources/VoiceTypeCore"
        ),
        .executableTarget(
            name: "VoiceType",
            dependencies: [
                "VoiceTypeCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/VoiceType",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "VoiceTypeCoreTests",
            dependencies: ["VoiceTypeCore"],
            path: "Tests/VoiceTypeCoreTests"
        ),
    ]
)
