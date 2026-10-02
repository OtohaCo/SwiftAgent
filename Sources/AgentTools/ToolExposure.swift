import Foundation

/// How a tool bound to a Run is offered to the model.
///
/// A `.declared` tool's definition is in every model request of the Run. A `.deferred` tool's is not,
/// so small context windows are not spent on tools the task may never need; the model learns of it
/// when a tool result declares it (`ToolResult.declaredTools`), from the Run's next request on. Until
/// then a call naming it fails as a call naming no bound tool does. Once declared, it is the same
/// tool with the same guarantees.
public enum ToolExposure: String, Codable, Sendable {
    case declared
    case deferred
}
