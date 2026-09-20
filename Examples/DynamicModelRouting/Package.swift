// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftAgentDynamicModelRoutingExample",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(name: "SwiftAgent", path: "../.."),
    ],
    targets: [
        .target(
            name: "DynamicModelRoutingSupport",
            dependencies: [
                .product(name: "AgentCatalog", package: "SwiftAgent"),
                .product(name: "AgentCore", package: "SwiftAgent"),
                .product(name: "AgentDecisions", package: "SwiftAgent"),
                .product(name: "AgentModels", package: "SwiftAgent"),
            ]
        ),
        .executableTarget(
            name: "DynamicModelRouting",
            dependencies: [
                "DynamicModelRoutingSupport",
                .product(name: "AgentCatalog", package: "SwiftAgent"),
                .product(name: "AgentCore", package: "SwiftAgent"),
                .product(name: "AgentDecisions", package: "SwiftAgent"),
                .product(name: "AgentJevProvider", package: "SwiftAgent"),
                .product(name: "AgentModels", package: "SwiftAgent"),
            ]
        ),
        .testTarget(
            name: "DynamicModelRoutingSupportTests",
            dependencies: [
                "DynamicModelRoutingSupport",
                .product(name: "AgentCatalog", package: "SwiftAgent"),
                .product(name: "AgentCore", package: "SwiftAgent"),
                .product(name: "AgentDecisions", package: "SwiftAgent"),
                .product(name: "AgentModels", package: "SwiftAgent"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
