import AgentModels

/// A call stopped before admission: its executor never ran and no mutation intent was written, so it
/// changed nothing and the model is told instead of the Run ending (ADR 0016). Fixed texts carry no
/// model-supplied value (tool name, arguments) and no thrown error's description.
package struct ToolPreAdmissionRefusal: Error, Sendable {
    package let payload: JSONValue

    package init(payload: JSONValue) { self.payload = payload }

    /// The tool's own `authorize` returned `.denied`.
    package static let denied = Self(code: "not_allowed",
        "This call was not allowed, so it did not run and nothing changed. Do not repeat it; "
            + "go on another way, or tell the user what you could not do.")

    /// The tool's own `authorize` threw something other than a `RecoverableToolError`.
    package static let authorizationFailed = Self(code: "authorization_failed",
        "Whether this call may run could not be decided, so it did not run and nothing changed. "
            + "Go on another way, or tell the user what you could not do.")

    /// The model named a tool this Run does not offer, or one not declared to it yet.
    package static let unknownTool = Self(code: "unknown_tool",
        "No tool by that name is available here, so nothing ran. Use one of the tools you were given, or go on without it.")

    private init(code: String, _ message: String) {
        payload = .object(["code": .string(code), "message": .string(message)])
    }

    /// The result the model sees for this refusal.
    package var result: ToolResult<JSONValue> {
        var result = ToolResult<JSONValue>(modelVisibleError: payload)
        result.notAdmitted = true
        return result
    }
}
