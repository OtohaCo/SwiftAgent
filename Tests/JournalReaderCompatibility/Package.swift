// swift-tools-version: 6.0
import Foundation
import PackageDescription

let sdkPath = ProcessInfo.processInfo.environment["SWIFTAGENT_SDK_PATH"] ?? "../.."
let package = Package(
    name: "JournalReaderCompatibility",
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "SwiftAgent", path: sdkPath)],
    targets: [.executableTarget(name: "JournalReaderCompatibility", dependencies: [
        .product(name: "AgentCore", package: "SwiftAgent"),
        .product(name: "AgentJournalFileStore", package: "SwiftAgent"),
        .product(name: "AgentModels", package: "SwiftAgent"),
        .product(name: "AgentTools", package: "SwiftAgent"),
    ])],
    swiftLanguageModes: [.v6]
)
