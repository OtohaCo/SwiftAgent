import Foundation

public enum LiveBudgetError: Error, Equatable, Sendable {
    case invalidLedger
    case providerLimit(provider: QualificationProvider, limit: Int)
    case totalLimit(limit: Int)
    case persistenceFailed
}

public struct LiveBudgetSnapshot: Equatable, Sendable {
    public let attempts: [QualificationProvider: Int]
    public let totalAttempts: Int
    public let perProviderLimit: Int
    public let totalLimit: Int
}

public actor LiveRequestBudget {
    private struct Stored: Codable {
        var attempts: [String: Int]
    }

    private let fileURL: URL?
    private let perProviderLimit: Int
    private let totalLimit: Int
    private var attempts: [QualificationProvider: Int]

    public init(fileURL: URL?, perProviderLimit: Int = 12, totalLimit: Int = 48) throws {
        guard perProviderLimit > 0, totalLimit > 0 else { throw LiveBudgetError.invalidLedger }
        self.fileURL = fileURL
        self.perProviderLimit = perProviderLimit
        self.totalLimit = totalLimit
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            let stored: Stored
            do { stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: fileURL)) }
            catch { throw LiveBudgetError.invalidLedger }
            var decoded: [QualificationProvider: Int] = [:]
            for (key, value) in stored.attempts {
                guard let provider = QualificationProvider(rawValue: key), value >= 0 else {
                    throw LiveBudgetError.invalidLedger
                }
                decoded[provider] = value
            }
            attempts = decoded
        } else {
            attempts = [:]
        }
    }

    public func reserve(_ provider: QualificationProvider) throws {
        let providerCount = attempts[provider, default: 0]
        guard providerCount < perProviderLimit else {
            throw LiveBudgetError.providerLimit(provider: provider, limit: perProviderLimit)
        }
        let total = attempts.values.reduce(0, +)
        guard total < totalLimit else { throw LiveBudgetError.totalLimit(limit: totalLimit) }
        attempts[provider] = providerCount + 1
        try persist()
    }

    public func snapshot() -> LiveBudgetSnapshot {
        .init(
            attempts: attempts,
            totalAttempts: attempts.values.reduce(0, +),
            perProviderLimit: perProviderLimit,
            totalLimit: totalLimit
        )
    }

    private func persist() throws {
        guard let fileURL else { return }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stored = Stored(attempts: Dictionary(uniqueKeysWithValues: attempts.map { ($0.key.rawValue, $0.value) }))
            try JSONEncoder().encode(stored).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw LiveBudgetError.persistenceFailed
        }
    }
}
