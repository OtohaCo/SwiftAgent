# SwiftAgent Context Policy

last-verified: 2026-09-20

SwiftAgent keeps three layers of context. They are not interchangeable.

| Layer | What it is | Lifetime |
| --- | --- | --- |
| Runtime configuration | Current system instructions, developer instructions if the model supports them, model, tools, structured output, limits, `AgentContextPolicy` | The `Agent` that opens the Session |
| Conversation context | Canonical transcript the model may see: user, assistant, assistant tool calls, tool results, committed provider continuation, accepted steering | The Session, restored from the journal checkpoint |
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
written back as Session history. Canonical checkpoints, tool identity checks,
budget accounting, Evidence, and mutation settlement continue to use formal
runtime state.

The default projector is identity. A Host-approved
`AgentResolvedReadOnlyToolSpan` can replace a complete failed/read-only and
later successful tool group with a source-marked summary. Permission failures,
mutation uncertainty, active calls, unresolved pairs, and constraints needed by
future work remain visible. A summary is not a user claim and cannot elevate
message authority.

The model remembering Resource A in the transcript is not permission to operate Resource A. Evidence still has to be in the `EvidenceLedger` for the required scope.

## Restore

A checkpoint may still contain the system message that was sent on an earlier
run. That record is a historical snapshot of runtime configuration, not the
active configuration. On restore, Core strips checkpoint `system` /
`developer` messages and prepends the instructions of the Agent that is
opening the Session. Conversation user / assistant / tool turns are kept.
The provider request therefore has exactly one current system message.

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

## Bounds

`AgentContextPolicy` distinguishes two failures:

- `AgentContextError.inputTooLarge` — one user input exceeds `maxInputUTF8Bytes`.
  Fail fast. The Session is unchanged.
- `AgentContextError.historyTooLarge` — accumulated history exceeds
  `maxActiveHistoryUTF8Bytes` (and never the journal's 16 MiB frame cap) and
  either there is no compactor or compaction cannot shrink the retained window.
  Typed failure, not a silent truncate.

Defaults: 8 MiB per input, 12 MiB encoded active history, 6 recent user turns
retained, **no compactor**. Raising `AgentJournal.maximumFrameSize` is not a
substitute for this policy.

## Compaction

The default policy is not automatic context management. Crossing the bound
without a host-supplied `AgentContextCompactor` fails closed. A mechanical
summary that only says earlier turns were dropped cannot resolve “use the
first one” after a search, so Core will not pretend that it can.

Hosts that accept lossy history opt in with
`AgentContextPolicy.lossyRetainedTurns(...)` or another `AgentContextCompactor`.
Then Core:

1. Keeps current runtime instructions.
2. Keeps the recent turn window unioned with any unresolved tool pair.
3. Asks the compactor to summarize only the dropped conversation.
4. Stores that summary as a **synthetic user** message so restore will not
   strip it with runtime system/developer configuration.
5. Writes a durable checkpoint and continues the Session.

The summary is not a real user utterance. It is stored as `.user` because:

- `.system` / `.developer` are stripped on restore and replaced by the current
  Agent instructions.
- Anthropic takes system as a top-level request field and rejects extra
  instruction messages after conversation has started.
- Apple Foundation Models keep system/developer out of the prompt transcript.
- OpenAI can carry extra system messages, but that is not portable.
- A new `ModelMessage` role would be a public API change for every encoder.

The stable prefix is `Conversation summary:`. Hosts that need domain memory
must supply a semantic compactor; Core will not add last-search or last-
selected resource fields.

Compaction never mints Evidence, receipts, or mutation settlement.
Unresolved mutation intents live in the journal mutation index. Compaction
must not split an assistant/tool pair that still has an open call ID.

## Journal growth

Each durable checkpoint still appends a frame. Compaction bounds the payload
of later frames, so growth is not a full-history copy every turn. Physical
file rollover / journal compaction is a separate follow-up (SAI-042); after a
`corruptTail` recovery, durable appends require `discardCorruptTail()`.
