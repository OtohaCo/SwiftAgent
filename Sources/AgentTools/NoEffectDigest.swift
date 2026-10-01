import AgentModels
import Crypto
import Foundation

/// Versioned proof binding, not a business idempotency key or an execution permit.
public struct ToolNoEffectDigest: Codable, Equatable, Sendable {
    public let encoding: String
    public let sha256: String
    public let utf8Bytes: Int

    package static func arguments(_ value: JSONValue) throws -> Self {
        let bytes = try canonicalBytes(value)
        return digest(bytes, encoding: "swiftagent-json-v1")
    }
    package static func operationKey(_ key: String) -> Self {
        digest(Data(key.utf8), encoding: "utf8-v1")
    }
    private static func digest(_ bytes: Data, encoding: String) -> Self {
        .init(encoding: encoding, sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), utf8Bytes: bytes.count)
    }

    /// UTF-8, no whitespace; object keys ordered by UTF-8 bytes. Preserve Unicode
    /// scalar sequences; escape quote/backslash and controls as lowercase \u00xx.
    /// Decimal uses base-10 non-exponent POSIX spelling (zero has no sign).
    /// This encoding is independent of AgentLoop's existing idempotency algorithm.
    package static func canonicalBytes(_ value: JSONValue) throws -> Data {
        func quoted(_ string: String) -> String {
            var result = "\""
            for scalar in string.unicodeScalars {
                switch scalar.value {
                case 0x22: result += "\\\""
                case 0x5c: result += "\\\\"
                case 0..<0x20: result += String(format: "\\u%04x", scalar.value)
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result + "\""
        }
        func encode(_ value: JSONValue) throws -> String {
            switch value {
            case .null: return "null"
            case .bool(let v): return v ? "true" : "false"
            case .number(var v):
                guard !v.isNaN else { throw ToolNoEffectError.invalidBinding }
                return v == 0 ? "0" : NSDecimalString(&v, Locale(identifier: "en_US_POSIX"))
            case .string(let v): return quoted(v)
            case .array(let v): return "[" + (try v.map(encode)).joined(separator: ",") + "]"
            case .object(let v):
                return "{" + (try v.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map {
                    quoted($0) + ":" + (try encode(v[$0]!))
                }).joined(separator: ",") + "}"
            }
        }
        return Data(try encode(value).utf8)
    }
}

/// Archival reference to the authoritative intent's unchanged idempotency key.
public struct ToolNoEffectOperationBinding: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case intentIdempotencyKey }
    public let source: Source
    public let key: ToolNoEffectDigest
}

/// Separate archival receipt summary. Its operation binding is not Receipt.operationID.
public struct ToolNoEffectReceiptSummary: Codable, Equatable, Sendable {
    public let operation: ToolNoEffectOperationBinding
    public let status: ToolReceipt.Status
    public let failure: ToolReceipt.Failure?
    public let confirmedTargets: [EvidenceReference]
    public let revision: String?
    package init(_ receipt: ToolReceipt) {
        operation = .init(source: .intentIdempotencyKey, key: .operationKey(receipt.operationID))
        status = receipt.status; failure = receipt.failure
        confirmedTargets = receipt.confirmedTargets; revision = receipt.revision
    }
}
