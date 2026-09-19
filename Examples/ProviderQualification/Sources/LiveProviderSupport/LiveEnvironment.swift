import Foundation

public struct LiveEnvironment: Sendable {
    private let values: [String: String]

    public init(process: [String: String] = ProcessInfo.processInfo.environment) {
        values = process.reduce(into: [:]) { result, entry in
            if let value = normalized(entry.value) { result[entry.key] = value }
        }
    }

    private init(values: [String: String]) {
        self.values = values
    }

    public static func load(
        process: [String: String] = ProcessInfo.processInfo.environment,
        fileURL: URL? = nil
    ) throws -> Self {
        var fileValues: [String: String] = [:]
        if let fileURL {
            let data: Data
            do { data = try Data(contentsOf: fileURL) }
            catch { throw LiveConfigurationError.unreadableEnvironmentFile }
            guard let text = String(data: data, encoding: .utf8) else {
                throw LiveConfigurationError.unreadableEnvironmentFile
            }
            for (offset, sourceLine) in text.components(separatedBy: .newlines).enumerated() {
                let lineNumber = offset + 1
                var line = sourceLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if line.hasPrefix("export ") {
                    line.removeFirst("export ".count)
                    line = line.trimmingCharacters(in: .whitespaces)
                }
                guard !line.contains("$("), !line.contains("${"), !line.contains("`"),
                      let separator = line.firstIndex(of: "=") else {
                    throw LiveConfigurationError.unsafeEnvironmentFile(line: lineNumber)
                }
                let key = String(line[..<separator])
                let rawValue = String(line[line.index(after: separator)...])
                guard isEnvironmentKey(key), let value = parseLiteral(rawValue) else {
                    throw LiveConfigurationError.unsafeEnvironmentFile(line: lineNumber)
                }
                if let value = normalized(value) { fileValues[key] = value }
            }
        }

        for (key, rawValue) in process {
            if let value = normalized(rawValue) { fileValues[key] = value }
        }
        return .init(values: fileValues)
    }

    public func value(for key: String, aliases: [String] = []) -> String? {
        if let value = values[key] { return value }
        for alias in aliases {
            if let value = values[alias] { return value }
        }
        return nil
    }
}

public func renderedEnvironmentFileStatus(_ fileURL: URL?) -> String {
    "environment_file=\(fileURL == nil ? "NONE" : "CONFIGURED")"
}

private func isEnvironmentKey(_ key: String) -> Bool {
    guard let first = key.unicodeScalars.first,
          CharacterSet.letters.contains(first) || first == "_" else { return false }
    return key.unicodeScalars.dropFirst().allSatisfy {
        CharacterSet.alphanumerics.contains($0) || $0 == "_"
    }
}

private func parseLiteral(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespaces)
    guard !value.contains("\n"), !value.contains("\r") else { return nil }
    guard let first = value.first else { return "" }
    if first == "\"" || first == "'" {
        guard value.count >= 2, value.last == first else { return nil }
        let inner = value.dropFirst().dropLast()
        guard !inner.contains(first) else { return nil }
        return String(inner)
    }
    guard !value.contains(where: { $0.isWhitespace || $0 == "#" }) else { return nil }
    return value
}
