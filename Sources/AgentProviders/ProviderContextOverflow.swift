import AgentModels
import Foundation

/// Narrow provider signals meaning "the request does not fit the model's context
/// window". Each rule names the service that documents or was observed to send
/// it. A match only selects `ModelProviderError.Kind.contextWindowExceeded`; the
/// provider's message is read for the match and never copied into the error.
enum ProviderContextOverflow {
    enum Signals: Sendable {
        /// OpenAI Responses and OpenAI-compatible local servers.
        case responses
        /// Anthropic Messages.
        case anthropic
    }

    /// Responses error object: a stream `error` payload, `response.error`, or
    /// the `error` member of an HTTP error body.
    static func isResponsesOverflow(_ error: [String: JSONValue]) -> Bool {
        // OpenAI: documented error code, sent in HTTP 400 bodies and stream failures.
        if text(error["code"]) == "context_length_exceeded" { return true }
        // llama.cpp server (llama-server): HTTP 400 with this error type.
        if text(error["type"]) == "exceed_context_size_error" { return true }
        return text(error["message"]).map(isLMStudioMessage) ?? false
    }

    /// Anthropic: HTTP 400 `invalid_request_error` whose message starts
    /// "prompt is too long" (for example "prompt is too long: 203073 tokens > 200000 maximum").
    static func isAnthropicOverflow(_ error: [String: JSONValue]) -> Bool {
        text(error["type"]) == "invalid_request_error"
            && text(error["message"])?.hasPrefix("prompt is too long") == true
    }

    /// Classifies the bounded body of a non-200 HTTP response.
    static func isOverflow(httpBody body: Data, signals: Signals) -> Bool {
        guard let object = try? ProviderJSON.decode(String(decoding: body, as: UTF8.self)) else { return false }
        switch (signals, object["error"]) {
        case (.responses, .object(let error)?): return isResponsesOverflow(error)
        // Older LM Studio servers send the message as a bare string.
        case (.responses, .string(let message)?): return isLMStudioMessage(message)
        case (.anthropic, .object(let error)?): return isAnthropicOverflow(error)
        default: return false
        }
    }

    /// LM Studio reports an overflow as code `unknown` / type `internal_error`
    /// (HTTP 500, or a stream `error` event), so only its message identifies it.
    /// Current servers (verified 2026-10-02) start with the first sentence below,
    /// sometimes followed by "(n_keep: … >= n_ctx: …)"; older servers send the
    /// second form, including its "context the overflows" wording.
    private static func isLMStudioMessage(_ message: String) -> Bool {
        let message = message.trimmingCharacters(in: .whitespaces)
        if message.hasPrefix("The number of tokens to keep from the initial prompt is greater than the context length") {
            return true
        }
        return message.hasPrefix("Trying to keep the first ")
            && message.contains(" tokens when context the overflows.")
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard case .string(let value)? = value else { return nil }
        return value
    }
}
