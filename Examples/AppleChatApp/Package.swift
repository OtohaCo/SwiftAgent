// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftAgentAppleChatExample",
    platforms: [.macOS(.v13), .iOS(.v16)],
    dependencies: [
        .package(name: "SwiftAgent", path: "../.."),
        .package(name: "SwiftAgentExecutionReportingSupport", path: "../ExecutionReportingSupport"),
        .package(name: "SwiftAgentProviderQualification", path: "../ProviderQualification"),
    ],
    targets: [
        .target(
            name: "AppleChatIntegration",
            dependencies: [
                .product(name: "AgentCore", package: "SwiftAgent"),
                .product(name: "AgentModels", package: "SwiftAgent"),
                .product(name: "AgentProviders", package: "SwiftAgent"),
                .product(name: "AgentTools", package: "SwiftAgent"),
                .product(name: "AgentUsage", package: "SwiftAgent"),
                .product(name: "ExecutionReportingSupport", package: "SwiftAgentExecutionReportingSupport"),
                .product(name: "LiveProviderSupport", package: "SwiftAgentProviderQualification"),
            ]
        ),
        .executableTarget(
            name: "AppleChatApp",
            dependencies: [
                "AppleChatIntegration",
                .product(name: "AgentUsage", package: "SwiftAgent"),
            ]
        ),
        .testTarget(
            name: "AppleChatIntegrationTests",
            dependencies: [
                "AppleChatIntegration",
                .product(name: "AgentCore", package: "SwiftAgent"),
                .product(name: "AgentModels", package: "SwiftAgent"),
                .product(name: "AgentUsage", package: "SwiftAgent"),
                .product(name: "ExecutionReportingSupport", package: "SwiftAgentExecutionReportingSupport"),
                .product(name: "LiveProviderSupport", package: "SwiftAgentProviderQualification"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
