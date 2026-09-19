# Provider Remediation Round 2 Closure

last-verified: 2026-09-19

## Scope

This review closes the eight findings in the bounded provider remediation
brief. The implementation baseline was
`fa25213d1d7618da46132f487f60710e874a0210`. The published
`1.0.0-rc.1` tag remains fixed at
`d2347f11c6a78f421708e897dae42a51a98d37ea`.

The round did not add another provider, change AgentCore orchestration, change
the journal schema, merge `main`, or publish a release.

## Finding Closure

| Finding | Disposition | Reproduction and result | Fix commit |
| --- | --- | --- | --- |
| F1 OpenAI terminal state can admit an invalid tool | Accepted, reproduced | The pre-fix terminal matrix accepted explicit illegal or contradictory item status in 14 cases. Fresh-run Agent tests prove invalid terminal state reaches no executor, while the healthy control executes once. | `396336595a09727d26d09d275aa6768b92c16b24` |
| F2 DeepSeek terminal state can admit an invalid tool | Accepted, reproduced | The same parameterized matrix and fresh-run executor controls cover DeepSeek independently. Raw status validation now precedes projections that omit status. | `396336595a09727d26d09d275aa6768b92c16b24` |
| F3 Legal DeepSeek incomplete output is rejected or over-trusted | Accepted, reproduced | A function call ending without `output_item.done` failed before the fix. Pending item identity and observed bytes are now retained; incomplete turns expose partial state but execute no call. | `396336595a09727d26d09d275aa6768b92c16b24` |
| F4 Continuation binding loses visible order | Accepted, reproduced | Per-kind aggregation could not distinguish reorder. An initial exact native-item comparison then rejected legal cross-item streaming interleaving in the full suite. The final implementation stores the normalized decoder-published order and validates it during restore. | `8f299589d84b6483af73b7427f467489b2e23dd0`, corrected by `2d6adfc0e97d792b6bbdbd021dd4befa724ff973` |
| F5 OpenAI function-only continuation loses native identity | Accepted, reproduced | One- and two-call function-only turns now retain native function item IDs and status through persistence and next-request encoding without inventing metadata for manually built history. | `396336595a09727d26d09d275aa6768b92c16b24` |
| F6 DeepSeek accepts a turn it cannot encode next | Accepted, reproduced | With thinking and registered host tools, a completed text-only turn without replayable same-turn reasoning now fails before assistant checkpoint. A valid reasoning turn encodes the next request. | `396336595a09727d26d09d275aa6768b92c16b24` |
| F7 Compactor ownership evidence is incomplete | Partially accepted | The reported remaining production race was not reproduced against the ownership fix in `62772b1`. The evidence gap was real: deterministic exit hooks and memory, durable, and reserved-mutation completion tests now wait for the old worker to resume and exit. | `bac9646fe8686b61fd87303b9c6780491150d28a` |
| F8 Public API and provider documentation are stale | Accepted | README, provider guides/matrix, versioning inventory, conformance matrix, changelog, and generated member inventory now describe the actual post-rc.1 provider surface. | `94b8d808e1e0aaba62aa27fe2a43c80fb2fcef84` plus this closure |

The stale provider-route callback finding was closed separately. Generation
ownership prevents callbacks from an old cleared/cancelled Run from restoring
candidate pinning. The deterministic late-callback regression is in
`90983c394822b8a9c156569bdce10d28a18037ac`.

## Terminal Status Contracts

Response terminal status is required and independent from output-item status.
Function argument JSON completion, argument-done, item-done, and response
terminal are separate facts.

### OpenAI Responses

| Item | Added | Item done | Completed snapshot |
| --- | --- | --- | --- |
| Message | non-null `in_progress` required | non-null `completed` required | non-null `completed` required |
| Reasoning | absent or `null` allowed; otherwise `in_progress` | absent or `null` allowed; otherwise `completed` | absent or `null` allowed; otherwise `completed` |
| Function call | absent or `null` allowed; otherwise `in_progress` | absent or `null` allowed; otherwise `completed` | absent or `null` allowed; otherwise `completed` |

Known contradictory values and unknown values such as `finalized` are rejected.
Future unrelated metadata remains tolerated.

### DeepSeek Responses

| Item | Added | Item done | Completed snapshot |
| --- | --- | --- | --- |
| Message | may be absent; if present must be `in_progress` and non-null | may be absent; if present must be `completed` and non-null | may be absent; if present must be `completed` and non-null |
| Reasoning | same rule as message | same rule as message | same rule as message |
| Function call | same rule as message | same rule as message | same rule as message |

For `response.incomplete`, every final item must exactly preserve the observed
identity and bytes. SwiftAgent does not extend a partial prefix, repair JSON,
invent done events, or execute a completed subset from an incomplete response.

## Continuation Binding

OpenAI `openai.responses.v2` and DeepSeek `deepseek.responses.v1` keep their
format identifiers. Newly created payloads add an optional
`visible_content_order` field containing the decoder-published visible sequence
after adjacent same-kind fragments are merged. Restore requires an exact match
to that sequence and separately validates per-kind totals, native items, and
tool-call order.

Payloads written before this field existed remain readable through the legacy
native-item kind-order check. Such payloads cannot retroactively prove a finer
cross-item interleaving order that they never stored; all newly written
payloads carry the stronger binding. No public API or journal schema changed.

## Test Evidence

RED evidence retained during implementation:

- Terminal matrix: 14 pre-fix failures across the OpenAI/DeepSeek status cases.
- DeepSeek incomplete: legal no-item-done partial rejected before the fix.
- Continuation: reordered and split visible sequences were accepted before
  binding; the first exact-order fix then failed the existing legal OpenAI
  interleaving regression.
- Independent review reproduced a DeepSeek continuation rejection for the
  documented `summary: []` reasoning shape and for a null compatibility field.
- Both adapters accepted `output_item.done` without first observing
  `function_call_arguments.done`, allowing one protocol transition to replace
  another.

Final targeted evidence:

- `ResponsesTerminalValidationTests`: 72 status-matrix cases plus 6 Agent
  executor controls, 0 failures. The matrix covers added, item-done, and final
  response snapshots for message, reasoning, and function-call items on both
  adapters.
- `ResponsesContinuationIntegrityTests`: 12 tests, including two parameterized
  DeepSeek metadata cases, 0 failures.
- `OpenAIResponsesStreamDecoderTests`: 11 tests, 0 failures.
- `OpenAIResponsesProviderTests`: 19 tests, 0 failures.
- `DeepSeekResponsesProviderTests`: 10 tests, 0 failures.
- `ToolResourceCoordinatorTests`: 11 tests, 0 failures.
- `AgentCompletionCommitTests`: 4 tests, 0 failures.

Final local macOS package evidence with Swift 6.4:

- XCTest: 126 passed, 0 failed.
- Swift Testing: 425 discovered, 420 passed, 5 operator/live tests skipped,
  0 failed.
- ExternalClient: 6 passed, 0 failed.
- iOS `arm64-apple-ios16.0` cross-build: passed.
- `swift test list`: 551 discovered test entries.

Skipped tests are the Anthropic and OpenAI real-cloud tests plus three Apple
live-model tests. DeepSeek has fixture/schema coverage only and no live suite.

## Protocol Sources

Verified on 2026-09-19:

- OpenAI Responses streaming events: `https://developers.openai.com/api/reference/resources/responses/streaming-events`
- OpenAI function output type, source revision `c51f68056113fadecd154f44ee220e381421349a`: `https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_function_tool_call.py`
- OpenAI output-item done type, source revision `7609337c1c7f26f49a237e2698df126f7983e948`: `https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_output_item_done_event.py`
- DeepSeek Responses reference: `https://api-docs.deepseek.com/api/create-response/`

## Independent Review Remediation

Claude Fable 5.1 reviewed `c2185912b5374c077fa268af9c6ec9860ed8a09c`
through the Herdr Claude panel on 2026-09-19. The full review and Codex
adjudication are recorded in
`2026-09-19-claude-fable-5-1-provider-remediation-review.md`.

The reported DeepSeek reasoning-metadata P1 was accepted and reproduced. The
adapter now accepts a documented summary array and null encrypted compatibility
metadata while continuing to reject non-null encrypted state. The reported
missing `function_call_arguments.done` P3 was elevated to a P2 contract gap
because this remediation explicitly treats argument completion, item
completion, and response completion as independent facts. Both adapters now
require exact argument agreement across those transitions before publishing a
complete call.

Claude then reviewed the exact remediation diff through
`0173179b1bb74e40afabac33ab30f5311bbb1c9b`, reran the prior DeepSeek
reproduction and the package/concurrency seals from an isolated copy, and
confirmed that both fixes are closed with no new P0, P1, or P2. The two
remaining P3 questions require a live DeepSeek tool turn: whether the service
emits `response.function_call_arguments.done`, and whether it accepts the raw
native metadata replayed by the next request.

## Residual Risk

- Live Anthropic, OpenAI, DeepSeek, and Apple model qualification was not run in
  this remediation. Normal CI remains credential-free and fixture based.
- The first live DeepSeek tool fixture must confirm the argument-done event and
  native-item replay shape described in the independent follow-up review.
- Legacy continuation payloads remain readable but have only the ordering
  evidence present when they were written.
- `DeepSeekReasoningEffort` is a closed public enum. Adding future vendor values
  is source-breaking for exhaustive client switches.
