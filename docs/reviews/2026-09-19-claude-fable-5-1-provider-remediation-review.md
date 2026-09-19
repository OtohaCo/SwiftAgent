# Claude Fable 5.1 Provider Remediation Review

last-verified: 2026-09-19

## Review Metadata

- Reviewer: Claude Fable 5.1 in the Herdr Claude panel
- Invocation: read-only prompt to pane `w1A:p5`
- Reviewed repository: `OtohaPlayer/SwiftAgent`
- Reviewed SHA: `c2185912b5374c077fa268af9c6ec9860ed8a09c`
- Baseline: `fa25213d1d7618da46132f487f60710e874a0210`
- Specification: `SwiftAgent-provider-remediation-round2-codex.md`
- Review date: 2026-09-19

The reviewer independently built and tested an isolated copy with Swift 6.4,
ran the full macOS package suite, ExternalClient, the iOS 16 cross-build, and
the concurrency seal, then added scratch-only fixtures to probe the reported
wire shapes. The scratch files were not copied into this repository.

## Findings And Adjudication

### DeepSeek Reasoning Metadata

**Claude severity:** P1. **Codex disposition:** Accepted.

`DeepSeekResponsesContinuation.validate` rejected any reasoning item carrying
`summary` or `encrypted_content`. DeepSeek's documented Responses example uses
`summary: []`, and a null compatibility field is semantically absent. Because
the stream decoder retained the raw item, continuation creation threw before
`responseCompleted`, discarding every affected thinking turn.

Repository RED evidence reproduced both variants in
`deepSeekDocumentedReasoningMetadataRemainsReplayable`. The fix accepts a
summary array and absent/null encrypted metadata, retains the raw item for the
next request, and still rejects non-null encrypted state. The follow-up tests
cover make, restore, and request encoding.

### Missing Function Arguments Terminal

**Claude severity:** P3. **Codex disposition:** Accepted as P2 for this round.

Both decoders allowed `output_item.done` to set `argumentsDone` when no
`function_call_arguments.done` event had arrived. The final bytes were still
prefix-checked and schema-validated, so this was not an authorization or
mutation-safety bypass. It nevertheless violated the remediation contract that
argument completion, item completion, and response completion are independent
facts.

`missingFunctionArgumentsDoneNeverReachesAgentExecutor` reproduced executor
entry for both adapters before the fix. The decoders now require the argument
terminal first and require byte-exact agreement at item completion.

### Route State Lifetime

**Claude severity:** P3. **Codex disposition:** Partially accepted, post-RC.

`ModelProviderRoute.admission` creates per-run state before validation. AgentCore
always clears it at physical drain, and successful direct route use already
created retained state before this remediation. Immediate stream-completion
cleanup would break the later mutation-boundary pinning contract. No production
change was made; direct users of the boundary lifecycle remain responsible for
calling clear.

### Incomplete Item Status

**Claude severity:** P3, needs live evidence. **Codex disposition:** Needs
evidence.

The decoders require a not-done item in a final incomplete snapshot to report
`incomplete` when a status is present. The reviewed references do not establish
whether either vendor may instead emit `in_progress` there. No permissive
change was made without a real fixture; the first operator live fixture should
record the exact wire status.

## Clean Areas

Claude reported no additional finding in terminal-status fail-closed behavior,
legal incomplete output handling, host-tool execution boundaries, ordered
continuation binding, OpenAI function-only identity, DeepSeek same-turn
reasoning, compactor ownership and exit evidence, stale route callback fencing,
public API/docs, or Swift concurrency.

## Review Outcome

The reviewed SHA had one blocking P1. That P1 and the accepted protocol P2 were
fixed after the review. No public API, journal schema, or continuation format
identifier changed. A focused Claude follow-up review of the remediation diff
is recorded below.

## Follow-Up Review

- Reviewer: Claude Fable 5.1 in the same Herdr panel
- Reviewed SHA: `0173179b1bb74e40afabac33ab30f5311bbb1c9b`
- Reviewed diff: `c2185912b5374c077fa268af9c6ec9860ed8a09c..0173179b1bb74e40afabac33ab30f5311bbb1c9b`
- Review date: 2026-09-19

Claude independently reran the package suite, ExternalClient, the concurrency
seal, and the prior reviewer-only DeepSeek reproduction from an isolated copy.
The documented `summary: []` and null encrypted-metadata streams now complete,
retain continuation, and replay the native item. Non-null encrypted metadata
still fails closed.

The follow-up also confirmed that both Responses decoders now require
`function_call_arguments.done` before `output_item.done`, require byte-exact
agreement at item completion, and leave legal incomplete streams unchanged.
The Agent-level negative regression proves that neither adapter reaches the
executor when the argument terminal is missing.

Claude reported no P0, P1, or P2 regression and concluded that both fixes are
closed with no new blocker. Two P3 live-evidence questions remain:

- Confirm that the live DeepSeek stream emits
  `response.function_call_arguments.done` for host function calls.
- Confirm that DeepSeek accepts replayed reasoning/message native items carrying
  the retained identifier, status, and empty summary metadata. If it does not,
  the request encoder should project the replay form without weakening decoder
  terminal validation.

These are operator live-qualification gaps, not defects reproduced against the
reviewed fixtures or documented contract.

### Final Delivery Delta

Claude performed one final read-only review of
`0173179b1bb74e40afabac33ab30f5311bbb1c9b..c473ebd8766f37c464fd53fbb68e1948936533f0`.
The delta contained only this review documentation and conditional
`FoundationNetworking` imports in two Linux provider test files. No file under
`Sources/` changed. Claude confirmed that every provider test file using
`URLRequest` now follows the repository's conditional import pattern, reran the
two touched suites (22 tests, 0 failures), and reported no new P0, P1, P2, or
P3. Production behavior remains the reviewed `0173179` implementation.
