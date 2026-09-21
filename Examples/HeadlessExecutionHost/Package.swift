// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftAgentHeadlessExecutionHost",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "HeadlessExecutionHost", targets: ["HeadlessExecutionHost"]),
        .executable(name: "HeadlessExecutionHostCLI", targets: ["HeadlessExecutionHostCLI"]),
    ],
    dependencies: [
        .package(name: "SwiftAgent", path: "../.."),
        .package(name: "SwiftAgentExecutionReportingSupport", path: "../ExecutionReportingSupport"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
    ],
    targets: [
        .target(
            name: "HeadlessExecutionHost",
            dependencies: [
                .product(name: "AgentCore", package: "SwiftAgent"),
                .product(name: "AgentModels", package: "SwiftAgent"),
                .product(name: "AgentTools", package: "SwiftAgent"),
                .product(name: "ExecutionReportingSupport", package: "SwiftAgentExecutionReportingSupport"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .executableTarget(
            name: "HeadlessExecutionHostCLI",
            dependencies: ["HeadlessExecutionHost"]
        ),
        .testTarget(
            name: "HeadlessExecutionHostTests",
            dependencies: ["HeadlessExecutionHost"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
