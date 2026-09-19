// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftAgentAppleChatExample",
    platforms: [.macOS(.v13), .iOS(.v16)],
    dependencies: [
        .package(name: "SwiftAgent", path: "../.."),
    ],
    targets: [
        .target(
            name: "AppleChatIntegration",
            dependencies: [
                .product(name: "AgentCore", package: "SwiftAgent"),
                .product(name: "AgentModels", package: "SwiftAgent"),
                .product(name: "AgentProviders", package: "SwiftAgent"),
                .product(name: "AgentTools", package: "SwiftAgent"),
            ]
        ),
        .executableTarget(
            name: "AppleChatApp",
            dependencies: ["AppleChatIntegration"]
        ),
        .testTarget(
            name: "AppleChatIntegrationTests",
            dependencies: [
                "AppleChatIntegration",
                .product(name: "AgentCore", package: "SwiftAgent"),
                .product(name: "AgentModels", package: "SwiftAgent"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
