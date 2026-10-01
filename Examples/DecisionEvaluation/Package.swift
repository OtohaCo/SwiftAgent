// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftAgentDecisionEvaluation",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "SwiftAgent", path: "../..")],
    targets: [.executableTarget(name: "DecisionEvalTrial", dependencies: [
        .product(name: "AgentDecisions", package: "SwiftAgent"),
        .product(name: "AgentJevProvider", package: "SwiftAgent"),
        .product(name: "AgentModels", package: "SwiftAgent"),
    ])],
    swiftLanguageModes: [.v6]
)
