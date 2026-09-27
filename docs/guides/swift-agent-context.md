# SwiftAgent Context Policy

last-verified: 2026-09-27

SwiftAgent keeps three layers of context. They are not interchangeable.

| Layer | What it is | Lifetime |
| --- | --- | --- |
| Runtime configuration | Current system instructions, developer instructions if the model supports them, model, tools, structured output, limits, `AgentContextPolicy` | The `Agent` that opens the Session |
| Formal conversation | Committed user, assistant and tool messages with stable IDs; provider continuation and applied steering remain part of recovery | The Session, indexed by the Journal |
| Trusted runtime state | Evidence, mutation intents, receipts, reconciliation, scheduler/resource ownership | In-process runtime. Not reconstructed from transcript |

## Run-specific model selection

`AgentSession` keeps the canonical conversation while each explicit Run may use
an immutable `AgentModelBinding`. The binding captures the provider, model,
deployment scope, configuration revision, projector, and optional token budget.
It is not stored as a replacement for the Session's runtime state. A failed
preflight leaves canonical history unchanged; a replacement Run waits for the
previous provider/tool drain before it starts.

Before a binding is used, Core checks provider/model identity, configured
capabilities, continuation origin, projection digest, and optional context
budget. Opaque continuation is accepted only for a compatible deployment by
default. A Host may explicitly use `AgentSemanticHandoffProjector` to remove
private provider state for a semantic handoff, but this is lossy and never
fabricates a native continuation or tool result.

## Request projection

`AgentContextProjector` receives a canonical snapshot and produces the messages
for one provider request. Its plan records source revision, source digest,
context epoch, version, and whether the result is lossy. The result is not
written back as Session history. Formal messages, tool identity checks,
budget accounting, Evidence, and mutation settlement continue to use formal
runtime state.

The default projector is identity. A Host-approved
`AgentResolvedReadOnlyToolSpan` can replace a complete failed/read-only and
later successful tool group with a source-marked summary. Permission failures,
mutation uncertainty, active calls, unresolved pairs, and constraints needed by
future work remain visible. A summary is not a user claim and cannot elevate
message authority.

The model remembering Resource A in the transcript is not permission to operate Resource A. Evidence still has to be in the `EvidenceLedger` for the required scope.

## Source-bound composition (RC4)

`AgentCompositeContextProjector` accepts an immutable Run snapshot of
`AgentContextMaterial` values. The Host loads and approves Skill, file and
retrieval text before building the binding. Each material names its Session,
identity, source version, kind, priority and whether it is
required. Retrieved text cannot assign itself a higher role. This API does
not fetch files, run tools or write a Journal. Materials are marked as source
data in the model request. Current runtime instructions and the latest user
request stay visible. Required material exceeding the material limit fails;
optional material is omitted with a recorded budget reason.

The projector sorts by priority, kind and ID. Duplicate identities must have
identical version, text and policy; a conflict fails. The defaults bound 64
entries, 256 KiB per material and 1 MiB of accepted material text. The final
request still passes Core's byte check and the existing token estimator for
messages, tools and structured output, with output/reasoning/protocol reserve.
An estimate is not actual Provider usage. If no safe view fits, the request
fails; formal conversation is unchanged by projection.

For older, closed text-only groups, the Host asks
`session.contextHistorySpan(start:count:)` for indexed Journal message IDs
and a content digest. An `AgentContextSummary` also supplies a generator
version. Every request checks the IDs and exact range again. Appending an
unrelated message does not invalidate it; changing covered content does.
Summary ranges cannot include current input, tool calls/results or provider
continuation. The Host pins earlier corrections or constraints using
`protectedMessageIDs` on the projector; their IDs cannot be summarized. The
summary is marked as Host-derived data in the model view, never formal user
history.

`session.contextToolExcerpt(callID:text:)` selects a committed successful
result of a registered read-only tool. The projector checks its Journal ID,
digest, read-only registration and complete call/result group, replacing only
that result's model-facing content. Call ID and result status remain paired;
the full output stays in the Journal. Mutation and error results are ineligible.

```swift
let span = try await session.contextHistorySpan(start: 0, count: 2)
let reports = AgentContextReportBuffer(capacity: 16)
let projector = AgentCompositeContextProjector(
    materials: [.init(id: "approved-skill", version: "v1", kind: .skill,
                      sessionID: session.id, text: skillText)],
    summaries: [.init(span: span, generatorVersion: "host-v1", text: hostSummary)]
)
let binding = try AgentModelBinding(
    profileID: "configured", profileRevision: "1", model: model,
    provider: provider, deployment: deployment, projector: projector,
    tokenBudget: tokenBudget, contextReports: reports
)
let run = try await session.run("Next task", using: binding)
_ = try await run.wait()
try await run.waitForDrain()
```

The bounded report records Session/Run/turn, revision/epoch, policy version,
source snapshot digest, accepted/omitted fingerprints and reasons,
material/request bytes, assembly time and token estimate when available. The
buffer holds at most 256 entries. It contains no raw source IDs, paths, prompt
text or opaque continuation. Fingerprints and digests are correlation hints,
not anonymization, authentication or authorization. The executable
`Examples/ExternalClient/Sources/ContextPipelineFixture` verifies two Sessions,
a large read-only result, a summary and a reopened full Journal with no keys
or network. Run `swift run --package-path Examples/ExternalClient ContextPipelineFixture`.
It verifies fixture behavior, not summary quality or live Provider behavior.

## Restore

The Journal restores committed user / assistant / tool messages for the
requested Session. The Agent that opens it supplies the current system
instructions. Earlier runtime instructions are not replayed as current
authority; the provider request has one current system message.

`EvidenceLedger` is in-memory on the Session. A process restart restores
conversation from the journal and does not restore Evidence. The host must
discover again if a later tool requires it.

## Cross-run transcript

A later Run's first provider request is the committed history plus the new
user turn. Tool results from a finished Run remain visible. Call and result
pairs stay ordered: no orphan result, no dangling call, no duplicate call ID.

Incomplete or uncommitted proposals are not rewritten as executed tools.
Refusal text does enter canonical history, and the Session can continue.
A provider without `.multiTurn` may complete a first user→assistant Run;
a follow-up that already has assistant history fails with
`unsupportedCapabilities(.multiTurn)` instead of dropping history.

Committed provider continuation may sit on the assistant message that owns
the completed tool batch. Discarded proposals drop their continuation.
Continuation is opaque provider state, not conversation meaning.

## Bounds and retention

`AgentContextPolicy` limits one input with `maxInputUTF8Bytes` before Run
admission. `maxModelContextUTF8Bytes` applies to the projected **request**
just before each provider call. It can fail with `historyTooLarge` if the
identity projection is too long. A Host may supply a source-marked projector
that produces a smaller valid request; the policy checks that resulting view.
Neither budget failure nor projection deletes formal messages or a mutation
identity. The default does not invent a summary. The optional model token
budget remains a separate check on the projected request.

The earlier `AgentContextCompactor` and `lossyRetainedTurns` path replaced
canonical history with a synthetic user summary. That path and its public
entry points are removed. Existing stores in the old format are rejected;
previously deleted text cannot be recovered by the new format. A Host can
project a lossy request view with `AgentContextProjector` without turning the
summary into a historical user utterance or Evidence.

Formal messages and the indexed mutation ledger remain subject to their
separate retention rules. Physical segment packing only copies necessary
facts to new managed files before deleting unreferenced old segments. See
[Journal](swift-agent-journal.md) and [ADR 0004](../adr/0004-journal-storage.md).
