import Foundation

enum DependencyGuard {
    static let dependencies: [String: Set<String>] = [
        "AgentModels": [],
        "AgentTools": ["AgentModels"],
        "AgentCore": ["AgentModels", "AgentTools"],
        "AgentProviders": ["AgentModels"],
        "AgentAppleProvider": ["AgentModels"],
        "WorkspaceAgent": ["AgentModels", "AgentTools", "AgentCore", "AgentProviders"],
    ]

    static func violations(_ source: String, module: String) -> [String] {
        var allowed = (dependencies[module] ?? []).union(["Foundation", "Swift"])
        if module == "AgentAppleProvider" { allowed.insert("FoundationModels") }
        if module == "AgentProviders" { allowed.insert("FoundationNetworking") }
        if module == "WorkspaceAgent" {
            allowed.insert("CryptoKit")
            allowed.insert("Crypto")
        }
        let pattern = #"\bimport\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z_][A-Za-z_0-9]*)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = source as NSString
        var failures = regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap {
            let imported = ns.substring(with: $0.range(at: 1))
            return allowed.contains(imported) ? nil : "\(module) cannot import \(imported)"
        }
        let domainPattern: String
        if module == "WorkspaceAgent" {
            domainPattern = #"(?i)\b(?:Otoha|Tingting|Music|Track|Playback|Playlist|AppleMusic|Podcast|Station|AIDiscovery|MainActor)\w*"#
        } else {
            domainPattern = #"(?i)\b(?:Otoha|Tingting|Music|Track|Playback|Playlist|AppleMusic|Podcast|Station|AIDiscovery|MainActor|WorkspaceAgent|WorkspaceFile|WorkspacePath)\w*"#
        }
        let domain = try! NSRegularExpression(pattern: domainPattern)
        failures += domain.matches(in: source, range: NSRange(location: 0, length: ns.length)).map {
            "\(module) contains forbidden token \(ns.substring(with: $0.range))"
        }
        return failures
    }
}
