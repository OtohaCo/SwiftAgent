# Native context, trusted controls and sampling usage

Status: implemented for issue #99, pending whole-candidate CI acceptance. This is
an extension after the RC6 candidate, not a new release or version assignment.
OtohaAI/sub2api production integration and live account qualification are separate.
See [ADR 0015](../adr/0015-native-context.md) and the
[public executable fixture](../../Examples/ExternalClient/Sources/NativeContextFixtureSupport/README.md).

## Select and qualify a mode

Catalog service descriptions, installed adapter executability and actual deployment
qualification are independent. `ModelCatalogEntry.compaction` may be absent/unknown;
`modesAreExhaustive == false` means omission is not proof of unsupported. Future
mode strings survive metadata decoding but cannot be executed. A compatible proxy
never acquires vendor beta capability from its family/model name.

| Mode | Configuration / wire | Minimum trigger | Replay |
| --- | --- | --- | --- |
| Anthropic threshold | `ModelAutomaticCompaction(.anthropicThreshold)`; `context_management.edits.compact_20260112`, `compact-2026-01-12` | 50,000 | Latest complete valid compaction plus accepted native suffix |
| Anthropic on-demand | `session.compact(.anthropicOnDemand)`; top-level `compaction:{type:"summarize"}`, `compact-2026-09-04` | None | Latest complete signed block then uncovered canonical suffix |
| OpenAI automatic | `ModelAutomaticCompaction(.openAIAutomatic)`; Responses `context_management` | 1,000 | Latest complete compaction item and subsequent items, including items in the same assistant |
| OpenAI standalone | `session.compact(.openAIStandalone)`; nonstream `POST /responses/compact` | None | Entire returned compacted window, including retained user items |

All four require explicit `NativeContextQualification(endpoint:resolvedModelNames:modes:)`
on their provider configuration. Host chooses the trigger; adapters reject values
below protocol minima rather than clamping. Trigger is not the hard preflight input
limit. `AgentModelBinding` must explicitly identify the actual deployment and frozen
root configuration. A legacy `Agent(model:provider:)` binding cannot enable or
restore native context. Route pins the actual candidate owner for native state and
rejects incompatible reordering/configuration changes rather than moving opaque
state to a fallback deployment.

```swift
let endpoint = URL(string: "https://api.openai.com/v1/responses")!
let provider = try OpenAIResponsesProvider(apiKey: hostCredential,
    nativeContext: .init(
        qualification: .init(endpoint: endpoint, resolvedModelNames: [resolvedName],
                             modes: [.openAIAutomatic]),
        automatic: .init(mode: .openAIAutomatic, triggerInputTokens: hostTrigger)))
let binding = try AgentModelBinding(profileID: "selected", profileRevision: catalogRevision,
    model: .init(provider: "openai", name: resolvedName), provider: provider,
    deployment: .init(serviceInstanceID: hostServiceID,
                      endpointScope: endpoint.absoluteString, apiDialect: "responses"))
```

## Operation and effective-view lifecycle

Drain preceding Run/tool work, then `let op = try await session.compact(mode: ...)`.
Observe `op.events`, await `op.wait()`, then `op.waitForDrain()`. A nil checkpoint
means a complete HTTP response produced no usable summary; retain its usage and
raw stop reason. Summary output is never a final assistant answer or an executor
command. Standalone tool_use is not dispatched. A Run can instead opt into one
controlled pre-generation compact using binding `AgentNativeContextPolicy`;
that phase reuses the current admitted Run owner and remaining deadline.

An idle operation has independent operation/invocation IDs and mutually exclusive
writer ownership. These are not mutation idempotency keys or remote exactly-once
guarantees. Cancellation before publication seal stops logical work; uncooperative
transport/projector/estimator work retains the reservation until physical drain.
No new Run or replacement actor can publish over it. After seal, existing durable
commit semantics apply. Definite publication failure keeps the old effective
checkpoint; commitUnknown requires recovery and never installs a guessed result.
Do not retry the entire Run or replay completed mutations.

Canonical user/assistant messages, tool outputs, receipts and pending/reconciliation
facts remain complete. A checkpoint changes only the effective request view. Core
verifies its stable source anchor, actual wire witness, parent/generation, accepted
native output and current publication history CAS. Normal append changes the head
without invalidating stable covered sources. Automatic native state and accepted
tool/mutation/no-effect facts publish together; steering or budgets discarding
native proposals also discard their dependent transition.

Build the verified effective context before projection, estimation and dispatch.
Ordinary projectors cannot reinterpret canonical ranges across a covered native
prefix. Native-aware suffix projectors must preserve bound continuation material.
An estimator must explicitly conform to `AgentNativeContextTokenEstimator` to
estimate a native window from qualified metadata/tokenization; ciphertext size is
not token count. Controls-aware budgets also require
`AgentConversationControlTokenEstimator`. Unknown token counts do not become zero.
Standalone prefix and resulting checkpoint-plus-tail each face their actual hard
budget. Anthropic final encoded body remains bounded at 32,000,000 bytes before
transport, including base64, tools, text, controls and escaped JSON.

Maintenance/pause/compaction-only is nonfinal; its follow-up still faces the Run
deadline. Configured binding and automatic maintenance bounds use the stricter
value when both exist, otherwise the configured value, or default four if absent.
A genuine complete final answer received before deadline retains the RC6 slow
final-publication guarantee. Tools never receive additional time from compaction.

## Trusted Anthropic tools and reminders

Explicitly enable `inlineToolChanges` and/or `runReminders` only after deployment
qualification. The top-level trusted tool baseline is frozen. Core derives each
append-only addition, same-name schema update or removal from the bound executor
registry; model-returned `tool_changes` cannot create execution permission. New
inline definitions use by-value; references only name previously trusted definitions.
`inline-tools-2026-09-15` and required clear-at beta are sent by the adapter.

A Host profile revision may change independently of a stable
`continuationBindingRevision` when only verified append-only registry metadata
changes. Actual model, root instructions, endpoint, dialect or binding changes
remain incompatible. Do not simply ignore all revisions.

```swift
try await priorRun.waitForDrain()
let op = try await session.compact(mode: .anthropicOnDemand)
_ = try await op.wait()
try await op.waitForDrain()
let controls = try AgentRunContextControls(reminder: "本轮请用中文回答")
let run = try await session.run(newRealUserInput, contextControls: controls,
                                capabilities: trustedCapabilities)
```

Reminder is a text-only native mid-conversation system control with
`clear_at:next_user_message`, separate from tool changes and cache controls. Complete
client tool-result groups count as user boundaries. One reminder is prepared per
new complete boundary, not per HTTP attempt or Run ID. Parallel results finish as
one group; adjacent user steering joins that wire turn before its one reminder.
User steering remains a real canonical user message. Threshold/pause plus reminder
is rejected rather than inventing a user boundary. Adapter replay of a frozen
request retains exactly the same controls; Core/Route does not automatically retry
provenance-qualified requests (a new attempt requires a managed invocation). Historical controls are never rewritten
or deleted to manufacture expiry. A summary's words do not inherit system authority.

The supported compact/reminder combination is: drained prior Run without active
reminder → idle whole-history on-demand compact → real new user → reminder → normal
tool loop. Threshold plus required reminder, compaction covering an active reminder
without a new legal user boundary, and compaction covering permanent mid-conversation
instructions fail locally. An unanswered controlled request ending system cannot
accept a following user (vendor forbids system→user); SDK rejects before admission.
An explicit resume/handoff API requires future protocol proof. No fake user/assistant
or mutation replay repairs it automatically.

## Preserved thinking and explicit fallback

Default replay keeps RC6 strict unchanged-prefix validation. Explicit
`thinkingPrefixMismatch: .error` or `.dropBlock` maps to
`thinking.block_binding.prefix_mismatch_behavior` with
`thinking-binding-controls-2026-08-01`. The adapter validates the qualified endpoint/resolved model and known
adaptive-only constraints; Host must qualify actual model/account support. Origin, payload integrity, visible tool calls and executor checks remain
mandatory. The policy never edits or re-signs stored thinking.

A qualified direct Anthropic on-demand adapter may set `preservedThinking: true`
and select one of `session.compactionBoundaries()` via `compact(through:)`. Only a
complete accepted assistant's actual sent request can supply a cut. Core reproduces
its exact encoded witness, validates the unchanged original prefix even under an
explicit mismatch fallback, and requires an adjacent unchanged tail with a legal
role boundary. Checkpoint lineage binds original payload identity to a verified
replacement prefix; it does not overwrite the old witness. Final projection and
image handling must preserve the entire kept tail. A second compact requires a
new actual request boundary in the current generation; old selectors are refused.
Current managed-tail support requires fixed root/tools, identity source view,
no nonempty historical controls, explicit deployment qualification and direct
Anthropic. Route does not expose this optional capability. Arbitrary cuts, mid-system
insertion and model/configuration changes fail locally.

Observe `.inputTransformations` from generation/compaction streams and responses.
Known `thinking_dropped` is typed by `thinkingWasDropped`; unknown kinds/reasons
remain visible. Whole snapshots replace previous diagnostics; absent/null keep them,
empty clears them. Encoded paths map to actual message/content digests and native
checkpoint identity, not guessed canonical indices. Log kind/reason/identity/count,
never full thinking, signature, ciphertext or credentials.

Fixtures prove local encoding, source correspondence and lifecycle. They cannot
verify real signatures. No new paid live qualification was run for #99. OtohaAI must
verify strict `.error` behavior on a supported account/model across tool changes,
reminders, multiple compactions and reopen, confirming no unexpected thinking_dropped.

## Sampling usage and pricing

`ModelUsage.iterationUsage` is an ordered replacement table, not another ledger.
Ordinals identify samples within one invocation. `.usage` remains a cumulative
response snapshot; partial iterations are observable before EOF/cancellation but
cannot manufacture complete aggregate fields. A complete table sums only categories
reported by every child. Parent and children never both charge the ledger. Explicit
empty tables replace detail with empty/unknown totals; missing/null keep prior data.
Known TTL writes plus cache reads must fit inclusive input, even when aggregate
write is absent. Unknown aggregate remains nil. Input already includes read/write;
reasoning is an output subset. Internal samples are not additional HTTP invocations.
OpenAI without reported iterations never receives fabricated breakdowns.

Ordinary Anthropic responses preserve old parent usage. A later unexpected iterations
table after parent counters were published is explicitly rejected as an unsupported
accounting-scope change; qualified native paths defer parent totals from the start.
Actual reported sampling models are retained; absent known message/compaction model
can inherit verified outer response identity, unknown kinds cannot guess it.

`ModelPromptPricing` selects the last inclusive/exclusive matching threshold for
one sampling's actual prompt length. The tier applies to all its input/output/read
categories, not merely excess tokens. Rates are exact Decimal currency units per
million. Nil is unknown; explicit zero is free. Service-scoped frozen catalog
revision/source prevents same-name model quotes crossing endpoints. The
[DynamicModelRouting example](../../Examples/DynamicModelRouting/README.md) maps
fictional sub2api priceTiers with exact numeric lexemes, prices each model/sample
separately, and reuses existing cache-write/TTL classification. Missing prices,
coverage or identity yield unknown total and an explicitly partial known subtotal.
It is not a universal billing engine or a production tariff guarantee.

## Persistence and compatibility

An OpenAI automatic response may contain a completed assistant answer before its
last compaction item, for example `[compaction, message, compaction]`. The SDK
finishes that answer without an extra maintenance request. Its canonical answer
and complete native output remain persisted; only the subsequent request view
starts at the latest compaction item. A response with compaction but no message
or client tool call remains maintenance and retains the bounded continuation
budget. This classification does not fabricate a provider stop reason in the Host.
The [official compaction guide](https://developers.openai.com/api/docs/guides/compaction)
describes output-array chaining and pruning before the latest compaction item
(rechecked 2026-10-12).

A paused follow-up dispatcher retains exclusive Session ownership. Finish or
close that dispatcher and wait for its physical drain before idle on-demand
compaction, then start the next direct Run. The SDK does not currently expose a
maintenance gap between queued replies. Do not borrow a writer, synthesize a
user boundary, or replay mutations to work around that ownership; a queue
maintenance hook needs a separate design.

`supportsNativeContext: true` opts File Journal into schema 11 within the existing
ledger/header/checkpoint mechanism. Default schema 3 stays supported; no automatic
migration disables old stores. Reader 11 can append old stores without claiming
native capability. The pre-feature schema-10 reader refuses empty and populated
schema-11 stores before inspect/append/maintenance, with unchanged bytes, both before
and after maintenance. Reopen with the original explicit deployment/root binding.
Do not discard native state to silently replay the oversized canonical history.

Old public initializer exact signatures remain available, including function
references. Old Provider conformers need not implement optional compaction/control
protocols. New optional Codable fields decode missing as nil, and new validated
types share constructor/decode validation. New `ModelEvent.inputTransformations`,
`ModelEvent.compactionProgress`, `AgentEvent.compaction` and new failure cases require
clients with exhaustive source switches to add handling. This prerelease API delta
is explicit; source compatibility is not claimed for exhaustive enum switches.
