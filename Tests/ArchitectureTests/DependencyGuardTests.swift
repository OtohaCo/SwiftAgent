import Foundation
import XCTest

final class DependencyGuardTests: XCTestCase {
    func testNetworkSDKIsLimitedToHTTPProviders() {
        XCTAssertEqual(DependencyGuard.violations("import FoundationNetworking", module: "AgentProviders"), [])
        XCTAssertEqual(DependencyGuard.violations("import FoundationNetworking", module: "AgentJevProvider"), [])
        for module in ["AgentModels", "AgentTools", "AgentCore", "AgentAppleProvider", "AgentDecisions", "AgentUsage", "WorkspaceAgent"] {
            XCTAssertFalse(DependencyGuard.violations("import FoundationNetworking", module: module).isEmpty)
        }
    }

    func testCryptoKitIsLimitedToWorkspaceHost() {
        XCTAssertEqual(DependencyGuard.violations("import CryptoKit", module: "WorkspaceAgent"), [])
        XCTAssertEqual(DependencyGuard.violations("import Crypto", module: "WorkspaceAgent"), [])
        for module in ["AgentModels", "AgentTools", "AgentCore", "AgentProviders", "AgentAppleProvider", "AgentDecisions", "AgentJevProvider", "AgentUsage"] {
            XCTAssertFalse(DependencyGuard.violations("import CryptoKit", module: module).isEmpty)
            XCTAssertFalse(DependencyGuard.violations("import Crypto", module: module).isEmpty)
        }
    }

    func testPosixIsLimitedToWorkspaceHost() {
        XCTAssertEqual(DependencyGuard.violations("import Darwin", module: "WorkspaceAgent"), [])
        XCTAssertEqual(DependencyGuard.violations("import Glibc", module: "WorkspaceAgent"), [])
        for module in ["AgentModels", "AgentTools", "AgentCore", "AgentProviders", "AgentAppleProvider", "AgentDecisions", "AgentJevProvider", "AgentUsage"] {
            XCTAssertFalse(DependencyGuard.violations("import Darwin", module: module).isEmpty)
            XCTAssertFalse(DependencyGuard.violations("import Glibc", module: module).isEmpty)
        }
    }

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
        let packages = try XCTUnwrap(manifest["dependencies"] as? [Any])
        XCTAssertEqual(packages.count, 1)
        let packageJSON = String(data: try JSONSerialization.data(withJSONObject: packages[0]), encoding: .utf8) ?? ""
        XCTAssertTrue(packageJSON.contains("\"identity\":\"swift-crypto\""), packageJSON)
        XCTAssertTrue(packageJSON.contains("swift-crypto.git"), packageJSON)
        let targets = try XCTUnwrap(manifest["targets"] as? [[String: Any]])
        let libraries = targets.filter { $0["type"] as? String == "regular" }
        XCTAssertEqual(Set(libraries.compactMap { $0["name"] as? String }), Set(DependencyGuard.dependencies.keys))
        for target in libraries {
            let name = try XCTUnwrap(target["name"] as? String)
            let deps = try XCTUnwrap(target["dependencies"] as? [[String: Any]])
            var moduleNames: Set<String> = []
            var productNames: Set<String> = []
            for dep in deps {
                if let byName = dep["byName"] as? [Any], let module = byName.first as? String {
                    moduleNames.insert(module)
                } else if let product = dep["product"] as? [Any], let productName = product.first as? String {
                    productNames.insert(productName)
                } else {
                    XCTFail("Unexpected dependency shape in \(name): \(dep)")
                }
            }
            XCTAssertEqual(moduleNames, DependencyGuard.dependencies[name], name)
            if name == "WorkspaceAgent" {
                XCTAssertEqual(productNames, ["Crypto"], name)
            } else {
                XCTAssertEqual(productNames, [], "\(name) must not link extra packages")
            }
            XCTAssertTrue((target["settings"] as? [Any] ?? []).isEmpty, "Isolation/build overrides require review")
        }
    }

    func testRejectsDomainAndActorLeaks() {
        for source in [
            "struct OtohaRequest {}", "let item: MusicTrack", "typealias T = PlaybackState",
            "struct PlaylistItem {}", "struct AIDiscoveryResult {}", "@MainActor final class Loop {}",
            "let executor: MainActor.Type", "// music example", "let track = 1",
            "struct WorkspaceFileStore {}", "import WorkspaceAgent",
        ] {
            XCTAssertFalse(DependencyGuard.violations(source, module: "AgentCore").isEmpty, source)
        }
        XCTAssertTrue(DependencyGuard.violations(
            "struct SearchResult {}\nactor Calculator {}", module: "AgentCore"
        ).isEmpty)
    }

    func testProvidersAndCoreCannotImportEachOtherOrTheWorkspaceHost() {
        XCTAssertFalse(DependencyGuard.violations("import AgentProviders", module: "AgentCore").isEmpty)
        XCTAssertFalse(DependencyGuard.violations("import AgentAppleProvider", module: "AgentCore").isEmpty)
        XCTAssertFalse(DependencyGuard.violations("import WorkspaceAgent", module: "AgentCore").isEmpty)
        XCTAssertFalse(DependencyGuard.violations("import AgentCore", module: "AgentProviders").isEmpty)
        XCTAssertFalse(DependencyGuard.violations("import AgentTools", module: "AgentProviders").isEmpty)
        XCTAssertFalse(DependencyGuard.violations("import WorkspaceAgent", module: "AgentProviders").isEmpty)
        XCTAssertFalse(DependencyGuard.violations("import AgentCore", module: "AgentAppleProvider").isEmpty)
        XCTAssertFalse(DependencyGuard.violations("import AgentTools", module: "AgentModels").isEmpty)
        XCTAssertFalse(DependencyGuard.violations("import AgentCore", module: "AgentTools").isEmpty)
        XCTAssertFalse(DependencyGuard.violations("import AgentCore", module: "AgentDecisions").isEmpty)
        XCTAssertFalse(DependencyGuard.violations("import AgentTools", module: "AgentDecisions").isEmpty)
        XCTAssertFalse(DependencyGuard.violations("import AgentCore", module: "AgentJevProvider").isEmpty)
        XCTAssertFalse(DependencyGuard.violations("import AgentTools", module: "AgentJevProvider").isEmpty)
        XCTAssertFalse(DependencyGuard.violations("import AgentProviders", module: "AgentJevProvider").isEmpty)
        XCTAssertTrue(DependencyGuard.violations(
            "import Foundation\nimport FoundationNetworking\nimport AgentModels\nimport AgentDecisions",
            module: "AgentJevProvider"
        ).isEmpty)
        XCTAssertTrue(DependencyGuard.violations(
            "import Foundation\nimport AgentModels\nimport AgentTools\nimport AgentCore\nimport AgentProviders",
            module: "WorkspaceAgent"
        ).isEmpty)
    }

    func testPublicAPIContractFixtureStaysOnThePublishedSurface() throws {
        let url = packageRoot.appendingPathComponent("Tests/AgentCoreTests/PublicAPIContractTests.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("@testable"))
        XCTAssertFalse(source.contains("AgentLoop("))
        XCTAssertFalse(source.contains("EvidenceLedger("))
        XCTAssertFalse(source.contains("ToolMutationAdmission"))
        XCTAssertTrue(source.contains("import AgentCore"))
    }

    func testExternalClientPackageStaysOnThePublishedSurface() throws {
        let root = packageRoot.appendingPathComponent("Examples/ExternalClient")
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(manifest.contains(".package(name: \"SwiftAgent\", path: \"../..\")"))
        XCTAssertTrue(manifest.contains("AgentCore"))
        XCTAssertTrue(manifest.contains("AgentDecisions"))
        XCTAssertTrue(manifest.contains("AgentJevProvider"))
        XCTAssertTrue(manifest.contains("AgentUsage"))
        XCTAssertFalse(manifest.contains("WorkspaceAgent"))
        XCTAssertFalse(manifest.contains("AgentAppleProvider"))
        let tests = root.appendingPathComponent("Tests/ExternalClientTests")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        var count = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            count += 1
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(source.contains("@testable"), url.path)
            XCTAssertFalse(source.contains("import WorkspaceAgent"), url.path)
            XCTAssertFalse(source.contains("import AgentAppleProvider"), url.path)
            XCTAssertTrue(source.contains("import AgentCore"), url.path)
            XCTAssertTrue(source.contains("import AgentDecisions"), url.path)
            XCTAssertTrue(source.contains("import AgentJevProvider"), url.path)
            XCTAssertTrue(source.contains("import AgentUsage"), url.path)
        }
        XCTAssertGreaterThan(count, 0)
    }

    func testLinuxPortableTargetSealIncludesUsageAccounting() throws {
        let script = try String(
            contentsOf: packageRoot.appendingPathComponent("Scripts/ci-linux.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(script.contains("AgentModels AgentTools AgentCore AgentProviders AgentDecisions AgentJevProvider AgentUsage"))
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
