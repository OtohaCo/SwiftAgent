// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftAgentExecutionReportingSupport",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "ExecutionReportingSupport", targets: ["ExecutionReportingSupport"]),
    ],
    dependencies: [
        .package(name: "SwiftAgent", path: "../.."),
    ],
    targets: [
        .target(
            name: "ExecutionReportingSupport",
            dependencies: [
                .product(name: "AgentCore", package: "SwiftAgent"),
                .product(name: "AgentModels", package: "SwiftAgent"),
                .product(name: "AgentTools", package: "SwiftAgent"),
            ]
        ),
        .testTarget(
            name: "ExecutionReportingSupportTests",
            dependencies: ["ExecutionReportingSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
