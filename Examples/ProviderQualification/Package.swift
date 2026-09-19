// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftAgentProviderQualification",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "LiveProviderSupport", targets: ["LiveProviderSupport"]),
        .executable(name: "ProviderQualification", targets: ["ProviderQualification"]),
    ],
    dependencies: [
        .package(name: "SwiftAgent", path: "../.."),
    ],
    targets: [
        .target(
            name: "LiveProviderSupport",
            dependencies: [
                .product(name: "AgentCore", package: "SwiftAgent"),
                .product(name: "AgentDecisions", package: "SwiftAgent"),
                .product(name: "AgentJevProvider", package: "SwiftAgent"),
                .product(name: "AgentModels", package: "SwiftAgent"),
                .product(name: "AgentProviders", package: "SwiftAgent"),
                .product(name: "AgentTools", package: "SwiftAgent"),
            ]
        ),
        .executableTarget(
            name: "ProviderQualification",
            dependencies: ["LiveProviderSupport"]
        ),
        .testTarget(
            name: "LiveProviderSupportTests",
            dependencies: ["LiveProviderSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
