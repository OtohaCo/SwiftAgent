// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftAgentExternalClient",
    platforms: [.macOS(.v13), .iOS(.v16)],
    dependencies: [
        .package(name: "SwiftAgent", path: "../.."),
        .package(name: "SwiftAgentExecutionReportingSupport", path: "../ExecutionReportingSupport"),
    ],
    targets: [
        .executableTarget(name: "JournalReplayFixture", dependencies: [
            .product(name: "AgentCore", package: "SwiftAgent"),
            .product(name: "AgentJournalFileStore", package: "SwiftAgent"),
            .product(name: "AgentModels", package: "SwiftAgent"),
            .product(name: "AgentTools", package: "SwiftAgent"),
        ]),
        .executableTarget(name: "ContextPipelineFixture", dependencies: [
            .product(name: "AgentCore", package: "SwiftAgent"),
            .product(name: "AgentJournalFileStore", package: "SwiftAgent"),
            .product(name: "AgentModels", package: "SwiftAgent"),
            .product(name: "AgentTools", package: "SwiftAgent"),
        ]),
        .executableTarget(name: "ScopedCapabilityFixture", dependencies: [
            .product(name: "AgentCore", package: "SwiftAgent"),
            .product(name: "AgentJournalFileStore", package: "SwiftAgent"),
            .product(name: "AgentModels", package: "SwiftAgent"),
            .product(name: "AgentTools", package: "SwiftAgent"),
        ]),
        .executableTarget(name: "FollowUpQueueFixture", dependencies: [
            .product(name: "AgentCore", package: "SwiftAgent"),
            .product(name: "AgentJournalFileStore", package: "SwiftAgent"),
            .product(name: "AgentModels", package: "SwiftAgent"),
            .product(name: "AgentTools", package: "SwiftAgent"),
        ]),
        .target(name: "BoundedReplanningFixture", dependencies: [
            .product(name: "AgentCore", package: "SwiftAgent"),
            .product(name: "AgentJournalFileStore", package: "SwiftAgent"),
            .product(name: "AgentModels", package: "SwiftAgent"),
            .product(name: "AgentTools", package: "SwiftAgent"),
        ]),
        .executableTarget(name: "BoundedReplanningProbe", dependencies: ["BoundedReplanningFixture"]),
        .testTarget(
            name: "ExternalClientTests",
            dependencies: [
                .product(name: "AgentCore", package: "SwiftAgent"),
                .product(name: "AgentJournalFileStore", package: "SwiftAgent"),
                .product(name: "AgentCatalog", package: "SwiftAgent"),
                .product(name: "AgentDecisions", package: "SwiftAgent"),
                .product(name: "AgentJevProvider", package: "SwiftAgent"),
                .product(name: "AgentModels", package: "SwiftAgent"),
                .product(name: "AgentProviders", package: "SwiftAgent"),
                .product(name: "AgentTools", package: "SwiftAgent"),
                .product(name: "AgentUsage", package: "SwiftAgent"),
                .product(name: "ExecutionReportingSupport", package: "SwiftAgentExecutionReportingSupport"),
                "JournalReplayFixture",
                "BoundedReplanningFixture",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
