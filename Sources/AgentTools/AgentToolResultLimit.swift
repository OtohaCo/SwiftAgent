import AgentModels
import Foundation

/// How much one tool result may add to the conversation (OAI-1521). A result whose JSON output encodes
/// to more than its tool's `maximumResultBytes` is replaced, before it is committed, by an object that
/// says so and keeps the beginning of the output as JSON text cut short:
///
/// ```json
/// {"truncated": true, "original_bytes": 3145730, "kept_bytes": 1047000,
///  "notice": "...", "partial_json": "\"aaaa..."}
/// ```
///
/// The whole replacement fits within the limit. Its Receipt, Evidence, declared tools and images are kept.
public enum AgentToolResultLimit {
    /// The limit of a tool that does not set its own: 1 MiB of encoded JSON output.
    public static let defaultBytes = 1024 * 1024
    /// The smallest limit a tool may set: room for the notice and some of the output.
    public static let minimumBytes = 4096

    /// `output` as committed under `limit`: unchanged when it fits.
    package static func capped(_ output: JSONValue, limit: Int) throws -> JSONValue {
        let encoded = try JSONEncoder().encode(output)
        guard encoded.count > limit else { return output }
        var keep = max(0, limit - 1024)
        for _ in 0..<16 {
            let replacement = cut(encoded, keeping: keep, limit: limit)
            let size = try JSONEncoder().encode(replacement).count
            if size <= limit { return replacement }
            // Escaping can grow the kept text; give back what overflowed, and a little more.
            keep = max(0, keep - (size - limit) - 64)
        }
        return cut(encoded, keeping: 0, limit: limit)
    }

    private static func cut(_ encoded: Data, keeping wanted: Int, limit: Int) -> JSONValue {
        var end = min(wanted, encoded.count)
        // Never split a UTF-8 sequence: step back over continuation bytes.
        while end > 0, end < encoded.count, encoded[encoded.startIndex + end] & 0xC0 == 0x80 { end -= 1 }
        let kept = String(decoding: encoded.prefix(end), as: UTF8.self)
        let notice = "This result was \(encoded.count) bytes, more than the \(limit) bytes this tool may add to "
            + "the conversation, so only its first \(end) bytes are kept, as JSON text cut short. "
            + "If you need the rest, ask for less at a time: a smaller range, a page, or a filter."
        return .object([
            "truncated": .bool(true),
            "original_bytes": .number(Decimal(encoded.count)),
            "kept_bytes": .number(Decimal(end)),
            "notice": .string(notice),
            "partial_json": .string(kept),
        ])
    }
}

extension ToolResult where Output == JSONValue {
    /// This result as committed under `limit`: its output cut when too large, everything else kept.
    package func capped(limit: Int) throws -> Self {
        var result = self
        result.output = try AgentToolResultLimit.capped(output, limit: limit)
        return result
    }
}
