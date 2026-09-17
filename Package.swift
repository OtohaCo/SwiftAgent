// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftAgent",
    products: [
        .library(name: "AgentModels", targets: ["AgentModels"]),
        .library(name: "AgentTools", targets: ["AgentTools"]),
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "AgentProviders", targets: ["AgentProviders"]),
    ],
    targets: [
        .target(name: "AgentModels"),
        .target(name: "AgentTools", dependencies: ["AgentModels"]),
        .target(name: "AgentCore", dependencies: ["AgentModels", "AgentTools"]),
        .target(name: "AgentProviders", dependencies: ["AgentModels"]),
        .testTarget(name: "ArchitectureTests"),
    ],
    swiftLanguageModes: [.v6]
)
