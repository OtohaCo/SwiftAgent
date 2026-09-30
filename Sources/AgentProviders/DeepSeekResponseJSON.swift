import AgentModels

/// Typed shape failure inside the decoder; public adapter boundaries map it to
/// the existing invalidResponse kind. Diagnostics never inspect error prose.
struct DeepSeekResponseShapeError: Error {}

enum DeepSeekResponseJSON {
    static func invalid() -> DeepSeekResponseShapeError { .init() }
    static func object(_ value: JSONValue?) throws -> [String: JSONValue] {
        do { return try ProviderJSON.object(value) } catch { throw invalid() }
    }
    static func decode(_ text: String) throws -> [String: JSONValue] {
        do { return try ProviderJSON.decode(text) } catch { throw invalid() }
    }
    static func string(_ value: JSONValue?) throws -> String {
        do { return try ProviderJSON.string(value) } catch { throw invalid() }
    }
    static func count(_ value: JSONValue?) throws -> Int? {
        do { return try ProviderJSON.count(value) } catch { throw invalid() }
    }
}
