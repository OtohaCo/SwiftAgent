// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftAgentExternalClient",
    platforms: [.macOS(.v13), .iOS(.v16)],
    dependencies: [
        .package(name: "SwiftAgent", path: "../.."),
    ],
    targets: [
        .testTarget(
            name: "ExternalClientTests",
            dependencies: [
                .product(name: "AgentCore", package: "SwiftAgent"),
                .product(name: "AgentModels", package: "SwiftAgent"),
                .product(name: "AgentTools", package: "SwiftAgent"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
