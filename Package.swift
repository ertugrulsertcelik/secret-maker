// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SecretBot",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SecretBotCore"),
        .executableTarget(name: "SecretBot", dependencies: ["SecretBotCore"]),
        .executableTarget(name: "secretbot-cli", dependencies: ["SecretBotCore"]),
    ]
)
