// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftAgent",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "AgentModels", targets: ["AgentModels"]),
        .library(name: "AgentTools", targets: ["AgentTools"]),
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "AgentProviders", targets: ["AgentProviders"]),
        .library(name: "AgentAppleProvider", targets: ["AgentAppleProvider"]),
        .library(name: "AgentDecisions", targets: ["AgentDecisions"]),
        .library(name: "AgentJevProvider", targets: ["AgentJevProvider"]),
        .library(name: "WorkspaceAgent", targets: ["WorkspaceAgent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
    ],
    targets: [
        .target(name: "AgentModels"),
        .target(name: "AgentTools", dependencies: ["AgentModels"]),
        .target(name: "AgentCore", dependencies: ["AgentModels", "AgentTools"]),
        .target(name: "AgentProviders", dependencies: ["AgentModels"]),
        .target(name: "AgentAppleProvider", dependencies: ["AgentModels"]),
        .target(name: "AgentDecisions", dependencies: ["AgentModels"]),
        .target(name: "AgentJevProvider", dependencies: ["AgentModels", "AgentDecisions"]),
        .target(
            name: "WorkspaceAgent",
            dependencies: [
                "AgentModels",
                "AgentTools",
                "AgentCore",
                "AgentProviders",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(name: "ArchitectureTests"),
        .testTarget(name: "AgentModelsTests", dependencies: ["AgentModels"]),
        .testTarget(name: "AgentToolsTests", dependencies: ["AgentTools", "AgentModels"]),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore", "AgentTools", "AgentModels"]),
        .testTarget(name: "AgentAppleProviderTests", dependencies: ["AgentAppleProvider", "AgentModels", "AgentTools", "AgentCore"]),
        .testTarget(name: "AgentProvidersTests", dependencies: ["AgentProviders", "AgentModels", "AgentTools", "AgentCore"]),
        .testTarget(
            name: "AgentDecisionsTests",
            dependencies: ["AgentDecisions", "AgentModels", "AgentTools", "AgentCore"]
        ),
        .testTarget(name: "AgentJevProviderTests", dependencies: ["AgentJevProvider", "AgentDecisions", "AgentModels"]),
        .testTarget(
            name: "WorkspaceAgentTests",
            dependencies: ["WorkspaceAgent", "AgentCore", "AgentTools", "AgentModels", "AgentProviders"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
