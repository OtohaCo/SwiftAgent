# SwiftAgent Typed Tools

## RC6 candidate: enterprise authorizer and action versions

In `requiredAudit`, centralized Host `AgentAuthorizer` runs for every model tool,
including `.notRequired`. Required `tool.authorize` still supplies a distinct
domain check; human confirmation can live only in the enterprise authorizer.
The defaulted `authorizationBinding(for:)` declares tool/implementation versions,
backend/account generation, resource revisions and immutable material versions
for exact action binding. The Host executor must enforce immutable inputs or
conditional writes itself. Approval does not freeze a mutable backend or cover
Provider egress. See [Audited Authorization](swift-agent-authorization-audit.md).

last-verified: 2026-10-02

Implement [AgentTool](../../Sources/AgentTools/AgentTool.swift) with
Codable, Sendable input and output types. Declare the JSON field names explicitly
with [ToolSchema](../../Sources/AgentTools/ToolSchema.swift); ordinary
Swift CodingKeys apply to encoding and decoding.

```swift
import AgentModels
import AgentTools

struct SearchTool: AgentTool {
    struct Input: Codable, Sendable { let query: String }
    struct Output: Codable, Sendable { let results: [String] }

    static let name = "search"
    static let description = "Search public resources"
    static let inputSchema = ToolSchema.object(
        properties: ["query": .string], required: ["query"]
    )
    static let outputSchema = ToolSchema.object(
        properties: ["results": .array(items: .string)], required: ["results"]
    )

    let policy: ToolPolicy
    let search: @Sendable (String) async throws -> [String]

    init(search: @escaping @Sendable (String) async throws -> [String]) throws {
        self.search = search
        policy = try .readOnly(authorization: .notRequired)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        ToolResult(output: Output(results: try await search(input.query)))
    }
}
```

The example explicitly opts out of authorization for a public read-only service.
The default policy requires authorization, and the default `authorize` hook denies
access. Override that hook to inspect typed input and host permissions. The host
injects service dependencies into the tool; ModelProvider never receives an executor.

## Images in Results (ADR 0012)

A tool may give the model images after its output, such as a screenshot or a
video frame: `ToolResult(output:images:)` with up to
`ModelImage.maximumImagesPerMessage` (8) `ModelImage` values. Make each image
from bytes the tool was allowed to read (`ModelImage(data:description:)` checks
type, the 3.75 MiB and 8,000-pixel limits and the text alternative); the SDK
fetches nothing. More images fail the call after the executor ran. With the
default `.reject` image policy, a Run that meets an image fails before its next
request, and so do later Runs until the Host chooses a policy. The result message holds
`.json(output)` followed by `.image` parts; whether the model is sent the
images or their text substitutes is the Run's `AgentImageInputPolicy` (see the
[context guide](swift-agent-context.md#images)). A durable journal needs
`supportsImageContent` to keep them; without it a read-only result with images
fails before commit, and a mutation's images are committed as text substitutes
so its settlement stands. A settled mutation replay returns its stored output
without images.

## Schemas and Type Erasure

The schema builder supports scalar types, objects, arrays and enumerations.
Object properties are optional unless listed in `required`; extra properties are
disallowed by default. A nullable value and an omitted property are different
contracts. Use `ToolSchema(json:)` for an explicit JSONValue schema. This bridge
preserves constraints; it does not certify that a validator supports them.

Schema declarations must agree with Codable behavior, including CodingKeys and
custom encoding. No reflection or sample-value inference generates a schema for
arbitrary Codable types. Schema validation is a separate runtime boundary.

## Recovering from invalid read-only output (unreleased)

Verified 2026-10-08. A Host can configure a read-only tool with
`recoverableErrors: .modelVisible`. In addition to explicit
`RecoverableToolError`, this policy converts output schema or JSON-encoding
failure into an `invalid_output` tool result with `isError == true`. The model
can choose another approach within the existing Run budgets. This changes
the prior terminal behavior of invalid output for tools using that policy;
see the [versioning guide](swift-agent-versioning.md).

The rejected output and its images, Evidence, receipts and declared tools are
discarded. Diagnostics use fixed wording, schema-declared property names and
array indices; an unrecognized output property and its remaining path become
`/<unrecognized>`. Neither output values nor dynamic keys are echoed. The
tool's declared read-only policy is a Host assertion; the SDK cannot undo
side effects of a misclassified executor.

The default `.failClosed` policy retains terminal failure, as do mutation
tools. Ordinary executor errors, authorization, Evidence, receipts,
persistence, cancellation and deadlines are not converted by this output
channel. Input validation remains the separate preparation-time
`invalid_arguments` result; it does not invoke the executor.

## Tools Defined at Runtime

A tool whose name, description and schemas are known only at runtime (declared by
a Host's configuration, or offered by an external server) conforms to
`RuntimeAgentTool`. Its input and output are `JSONValue`, and it supplies
`runtimeDefinition`; the type's static name, description and schemas are
placeholders, so one type can serve many tools.

- Every tool's `definition` is what the model sees and what the registry
  validates arguments and output against. For an ordinary `AgentTool` it
  defaults to the type's static values.
- Registration, schema validation, capability bindings and mutation admission
  use the definition, read once when the tool is registered. A definition must
  not change for the life of a tool instance.
- Authorization, Evidence and Receipts are unchanged.
- A name that comes from the instance rather than the type must be 1 to 64
  letters, digits, `_` or `-`, which every provider accepts. Tools named in code
  keep their names.
- A runtime name is part of durable mutation identity (operation ID, tool name,
  arguments). Keep names stable, and namespace them per source (for example
  `cap_export`), so that a name is never reused for a different operation.
- The definition's output schema is required. Schemas must stay within the
  supported subset; a Host converts external schemas (for example MCP's, which
  may use `$ref`, `anyOf` or `format`) before registering them. One invalid
  tool fails the whole registration.
- A wrapper generic over `Base: AgentTool` must forward `definition`. Code must
  identify tools by `definition.name`, never by `T.name` or
  `type(of: tool).name`, which are placeholders for runtime tools.

## Deferred Tools (unreleased)

Every model request carries the definitions of the tools it may call. With many
tools that can fill a small context window before the conversation starts. A
capability binding can therefore bind a tool as `.deferred`: it is part of the
Run, but its definition is not sent until a tool result declares it. This is the
same idea as Anthropic's `defer_loading` with tool search.

```swift
// The Host binds a few core tools and defers the rest.
let binding = try await session.bindCapabilities(
    identity: "project-B", version: "v1",
    backendInstanceID: "local-tools", backendVersion: "v1",
    allowedResources: resources,
    tools: [.init(id: "find_tools", version: "v1", tool: findTools)]
        + others.map { .init(id: $0.definition.name, version: "v1", tool: $0, exposure: .deferred) }
)

// Its "find tools" tool declares what it found for the next request.
func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
    let names = index.search(input.task, limit: 5)
    return ToolResult(output: Output(tools: names), declaredTools: names)
}
```

- `AgentCapabilityTool.exposure` defaults to `.declared`. Tools given to
  `Agent(tools:)` are always declared.
- A Run starts with the binding's declared tools. Once a result that declares
  tools is committed, the Run's next model request, its token estimate and the
  Provider capability check include those definitions. Within a Run the set only
  grows; the next Run starts again from its binding.
- A declared name must be exactly the name of a tool the Run has. Otherwise the
  call fails with `ToolRegistryError.unknownTool`, as an invalid output does.
  Like output validation, this check follows the executor, so a mutation tool's
  effect may already have happened and the call needs reconciliation.
  Declaring grants nothing: the declared tool's calls still pass authorization,
  Evidence, resource scope, mutation admission and Receipt validation.
- Deferral is not an access boundary. Any tool result of the Run can declare
  any bound tool, including a tool whose output comes from untrusted content.
  Bind only tools the Run may use.
- Declared definitions count toward the token budget from the next request. A
  declaration that does not fit fails that request with `contextBudgetExceeded`,
  and the set never shrinks within the Run, so declare a few tools at a time.
  Each declaration also changes the request's tool list, which a Provider's
  prompt cache treats as a new prefix.
- A call naming a deferred tool that has not been declared fails exactly as a
  call naming no bound tool: preparation throws `unknownTool` before any
  authorization, required audit records the proposal as `preparation_rejected`,
  and the Run fails. Bound but undeclared is not a weaker way to be callable.
- A settled mutation replay returns its stored output and declares nothing. Put
  discovery in a read-only tool.
- The declared set is request view state of one Run and is not journaled. A Run
  never resumes mid-loop: after a restart the Journal restores history, mutation
  intents, Receipts and audit facts, each recorded per call whatever the tool's
  exposure, and the next Run uses a new binding. Earlier calls to a deferred tool
  stay in history; if the model calls it again in a later Run before it is
  declared, that call fails as above. A Host can declare up front the tools a
  conversation has already used.
- `AgentCapabilityInfo.Tool.exposure` reports each tool's exposure. It is
  encoded only for `.deferred`, so a binding without deferred tools encodes as
  before. Deferred tools count toward the binding's reach: a deferred mutation
  tool still requires a durable Journal at Run start.

## Registry Validation

The runtime registers `[any AgentTool]` when you construct `Agent`. Duplicate
names and invalid input/output schemas fail at Agent initialization. Preparation
requires a complete, known call with the same call ID as its runtime context.
It decodes a strict JSON object, validates the schema and decodes the Swift
input before the scheduler receives a prepared call. The decoded Sendable input
is retained for invocation. Tool names and call IDs use exact matching without
Unicode normalization. Duplicate keys, including escaped spellings and
canonically equivalent Unicode keys that Swift dictionaries would merge, are
rejected rather than collapsed.

`ToolRegistry`, `AnyAgentTool`, and `PreparedToolCall` are package-only
runtime types. Host apps pass concrete `AgentTool` values. They do not type-erase
tools, inspect the registry, or hold prepared invocation objects. Preparation
does not grant authorization or prove execution succeeded. Invocation rechecks
context and policy, then validates the encoded output before returning it.

The supported schema vocabulary is deliberately bounded:

| Area | Supported keywords |
| --- | --- |
| General | Boolean schemas, `type` (single type or union), `enum`, `const` |
| Objects | `properties`, `required`, `additionalProperties` (boolean or schema) |
| Arrays | `items` (one schema), `minItems`, `maxItems` |
| Strings | `minLength`, `maxLength` (Unicode scalar count) |
| Numbers | `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum` |
| Annotations | `title`, `description`, `$comment`, `default`, `examples` |

Unknown keywords, including references, composition, patterns and format rules,
are registration errors. Annotations never insert defaults or transform data.
Numeric validation uses JSONValue's Decimal range; booleans are not numbers,
integers must have no fractional part, and null does not satisfy a required string.
Enum, const and property comparisons use exact Unicode code points; they do not
apply Swift String's canonical equivalence.
Limits apply to their corresponding instance type, so a schema should declare
`type` when it needs to restrict that type.

Keyword semantics follow the [JSON Schema validation vocabulary](https://json-schema.org/draft/2020-12/json-schema-validation)
and [object reference](https://json-schema.org/understanding-json-schema/reference/object)
within this subset. This is not a complete dialect implementation. Schema errors
identify the tool and schema JSON Pointer; argument/output errors identify the
value JSON Pointer and failed keyword without including its value.

## Execution Policy

[ToolPolicy](../../Sources/AgentTools/ToolPolicy.swift) distinguishes
effect, scheduling, idempotency, timeout and authorization. Mutation declarations
require exclusive execution; timeouts must be positive. Invalid configurations
throw instead of crashing the host. Idempotency is a declaration, not automatic
retry permission; keyed calls require a nonblank host-supplied key.

`ToolContext` carries session, run and call identities, an optional monotonic
deadline and an optional idempotency key. These values belong to the runtime, not
model arguments. Tools can use them to associate external operations with a run.

The typed `execute` method implements a host operation. Calling it directly does
not enforce execution policy. Registry validation, scheduler timeouts, evidence
checks and receipt verification are separate runtime responsibilities. See the
[conformance matrix](swift-agent-conformance-matrix.md) for the permanent regression evidence.

`AgentCapabilityBinding` optionally freezes one Run's registry, executors and
declared backend version. The exact resource set is checked on preparation
and again at final execution admission after async authorization and durable
mutation intent. Revocation applies even to `authorization: .notRequired`.
This does not replace Host authorization or Evidence. The Host must map model
arguments to honest resource identities and keep a stable backend handle;
`Sendable` does not freeze an underlying mutable service. This is not an OS
sandbox or a defense against a trusted Host bypassing the Agent execution path.

The package invocation bridge checks cancellation and deadline around decoding,
authorization and execution. It does not interrupt an uncooperative executor or
schedule parallel/exclusive lanes. Timeout enforcement belongs to orchestration
around the bridge.

The runtime supplies active run control; [ToolScheduler](swift-agent-scheduler.md)
enforces per-tool deadlines, parallel groups and resource leases around this bridge. A prepared call
can narrow its original context deadline when dispatched, but cannot extend it.

The bridge rejects mutation until its complete integrity path is available.
Read-only receipt-required invocations use the [receipt contract](swift-agent-receipts.md).
`ToolResult` separates typed output, evidence and an optional executor receipt;
ordinary output is not a verified mutation success. Input and output coding failures
are classified separately, and executor errors and CancellationError propagate.

Tools can return [Evidence](swift-agent-evidence.md) with their output and declare
typed evidence requirements. Publication happens after output validation; the
runtime supplies run/session scope rather than trusting scope in model arguments.

## Confirmed no-effect mutation (implemented, unreleased)

[ADR 0010 implementation](swift-agent-confirmed-no-effect.md) provides
a mutation-only explicit opt-in, with whole-operation trusted executor
confirmation and one reliable proof/abort/error/history/audit commit. Ordinary
mutation errors stay closed; failed/empty-target Receipt alone is insufficient.
Read-only classification cannot be used to bypass mutation guarantees.
