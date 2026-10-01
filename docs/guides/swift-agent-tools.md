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

last-verified: 2026-09-29

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

## Schemas and Type Erasure

The schema builder supports scalar types, objects, arrays and enumerations.
Object properties are optional unless listed in `required`; extra properties are
disallowed by default. A nullable value and an omitted property are different
contracts. Use `ToolSchema(json:)` for an explicit JSONValue schema. This bridge
preserves constraints; it does not certify that a validator supports them.

Schema declarations must agree with Codable behavior, including CodingKeys and
custom encoding. No reflection or sample-value inference generates a schema for
arbitrary Codable types. Schema validation is a separate runtime boundary.

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

## Confirmed no-effect mutation candidate

[ADR 0010 implementation candidate](swift-agent-confirmed-no-effect.md) provides
a mutation-only explicit opt-in, with whole-operation trusted executor
confirmation and one reliable proof/abort/error/history/audit commit. Ordinary
mutation errors stay closed; failed/empty-target Receipt alone is insufficient.
Read-only classification cannot be used to bypass mutation guarantees.
