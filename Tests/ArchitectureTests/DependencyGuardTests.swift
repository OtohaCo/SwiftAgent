import Foundation
import XCTest

final class DependencyGuardTests: XCTestCase {
    func testPlatformSDKIsAllowedOnlyInItsDedicatedAdapter() {
        XCTAssertEqual(DependencyGuard.violations("import FoundationModels\nimport AgentModels", module: "AgentAppleProvider"), [])
        for module in ["AgentModels", "AgentTools", "AgentCore", "AgentProviders"] {
            XCTAssertFalse(DependencyGuard.violations("import FoundationModels", module: module).isEmpty)
        }
        XCTAssertFalse(DependencyGuard.violations("import AgentTools", module: "AgentAppleProvider").isEmpty)
        XCTAssertFalse(DependencyGuard.violations("import AgentCore", module: "AgentAppleProvider").isEmpty)
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testPackageSourcesRespectBoundaries() throws {
        for module in DependencyGuard.dependencies.keys.sorted() {
            let root = packageRoot.appendingPathComponent("Sources/\(module)")
            let files = try XCTUnwrap(FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil
            ))
            var count = 0
            for case let url as URL in files where url.pathExtension == "swift" {
                count += 1
                let source = try String(contentsOf: url, encoding: .utf8)
                XCTAssertEqual(DependencyGuard.violations(source, module: module), [], url.path)
            }
            XCTAssertGreaterThan(count, 0, "Missing sources for \(module)")
        }
        let tests = packageRoot.appendingPathComponent("Tests/AgentCoreTests")
        if FileManager.default.fileExists(atPath: tests.path) {
            let files = try XCTUnwrap(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
            for case let url as URL in files where url.pathExtension == "swift" {
                let source = try String(contentsOf: url, encoding: .utf8)
                // Test frameworks and the module under test are valid imports here.
                let testSource = source.replacingOccurrences(of: "import XCTest", with: "")
                    .replacingOccurrences(of: "import Testing", with: "")
                    .replacingOccurrences(of: "import AgentCore", with: "")
                XCTAssertEqual(DependencyGuard.violations(testSource, module: "AgentCore"), [], url.path)
            }
        }
    }

    func testResolvedManifestHasOnlyApprovedDependencyDirections() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "package", "--package-path", packageRoot.path,
                             "--scratch-path", scratch.path, "dump-package"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((manifest["dependencies"] as? [Any])?.count, 0)
        let targets = try XCTUnwrap(manifest["targets"] as? [[String: Any]])
        let libraries = targets.filter { $0["type"] as? String == "regular" }
        XCTAssertEqual(Set(libraries.compactMap { $0["name"] as? String }), Set(DependencyGuard.dependencies.keys))
        for target in libraries {
            let name = try XCTUnwrap(target["name"] as? String)
            let deps = try XCTUnwrap(target["dependencies"] as? [[String: Any]])
            let names = try deps.map { dep in
                let value = try XCTUnwrap((dep["byName"] ?? dep["target"]) as? [Any])
                return try XCTUnwrap(value.first as? String)
            }
            XCTAssertEqual(Set(names), DependencyGuard.dependencies[name], name)
            XCTAssertTrue((target["settings"] as? [Any] ?? []).isEmpty, "Isolation/build overrides require review")
        }
    }

    func testRejectsDomainAndActorLeaks() {
        for source in [
            "struct OtohaRequest {}", "let item: MusicTrack", "typealias T = PlaybackState",
            "struct AIDiscoveryResult {}", "@MainActor final class Loop {}",
            "let executor: MainActor.Type", "// music example", "let track = 1",
        ] {
            XCTAssertFalse(DependencyGuard.violations(source, module: "AgentCore").isEmpty, source)
        }
        XCTAssertTrue(DependencyGuard.violations(
            "struct SearchResult {}\nactor Calculator {}", module: "AgentCore"
        ).isEmpty)
    }

    func testRejectsForbiddenImportsIncludingInactiveAndScopedImports() {
        for source in [
            "import SwiftUI", "#if os(iOS)\nimport MusicKit\n#endif",
            "@preconcurrency import Observation", "import struct AVFoundation.AVTime",
            "import Foundation; import StoreKit", "import Tingting",
            "import AgentProviders", "import OpenAI",
        ] {
            XCTAssertFalse(DependencyGuard.violations(source, module: "AgentCore").isEmpty, source)
        }
        XCTAssertTrue(DependencyGuard.violations(
            "import Foundation\nimport AgentModels\nimport AgentTools", module: "AgentCore"
        ).isEmpty)
    }
}
