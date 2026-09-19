# SwiftAgent RC.2 whole-candidate independent review

> Independent reviewer output, preserved verbatim. Codex dispositions and the
> remediation review are recorded in
> [the follow-up review](2026-09-19-claude-fable-5-1-rc2-followup.md) and the
> [RC.2 full audit](2026-09-19-swift-agent-1.0-rc.2-full-audit.md).

- Reviewer model/runtime: Claude Fable 5.1 (`claude-fable-5-1`). This is the requested model.
- Repository: `/Users/lilong/Works/Tingting/SwiftAgent`, branch `plan/swift-agent-rc2`
- Baseline: annotated tag `1.0.0-rc.1` → `d2347f11c6a78f421708e897dae42a51a98d37ea` (dereferenced and confirmed)
- Candidate: `9be07d50c1c276c77661856694d1a30f4e77ad48` (27 commits since baseline; 78 files, +10,628/−422; 21 production source files changed)
- Date: 2026-09-19
- Mode: read-only. The candidate was exported with `git archive` to `/tmp`; no worktree, branch, tag, file, or index change was made in the repository. Reviewer-only reproduction tests were written only in scratch copies and deleted.
- Method: baseline-to-candidate diff plus current-architecture inspection by one lead reviewer and three parallel sub-reviewers (core/journal, providers/continuation, API/architecture/portability), all reading source and tests directly. Prior review documents in `docs/reviews/` were not used as proof.
- Verification runs on the candidate export (Swift 6.4, Xcode 27.0, macOS 27): `swift build` clean with no warnings; full `swift test --disable-sandbox --no-parallel` exit 0 (Swift Testing: 168 + 131 + 84 + 24 + 18 + 10 + 9 tests; XCTest: 56, 30, 29, 28, 26, 21, 11, 10, 8, 5, 4, 3, 2 across targets; 0 failures; 5 credentialed live tests skipped by policy); `Scripts/ci-concurrency-seal.sh` exit 0 (11 + 4 required cases); ExternalClient 7/7; `JevDecision` example runs in fixture mode; iOS 16 cross-build of the six portable targets succeeds; public symbol graphs generated for rc.1 and candidate and diffed by precise identifier. Linux and live provider calls were not executed.

## Actionable findings

No P0 or P1 findings exist. One P2 and seven P3 findings follow, ordered by severity.

### FABLE-RC2-001 — P2 — DeepSeek thinking+tools session becomes permanently unusable after one continuation-less assistant turn

- Path: `Sources/AgentProviders/DeepSeekResponsesRequestEncoder.swift:26-37`; `Sources/AgentProviders/DeepSeekResponsesStreamDecoder.swift:355-374`
- Problem: the encoder throws `ModelProviderError(.invalidRequest)` for every `.assistant` history message that has no restorable DeepSeek continuation whenever `reasoningEffort != .none` and the request carries tools. The decoder's `incomplete()` path (`max_output_tokens`, `content_filter`) never calls `DeepSeekResponsesContinuation.make`, so an incomplete turn is published with content but no continuation. Core commits that turn to canonical history as `.incomplete(...)` (`AgentLoop.swift:152`).
- Impact / failure path: after one truncated DeepSeek response in a thinking+tools session, every subsequent Run in that session fails before network I/O. The same dead-end applies to any assistant turn that legitimately has no continuation (history created with thinking disabled or without tools, host-side history editing, or a session migrated from another provider). No security impact: nothing is executed or replayed; it is a functional dead-end. The guide (`docs/guides/swift-agent-deepseek-provider.md:47-49, 82-86`) documents the completed-turn requirement but not this consequence.
- Reproduction (fixture, sub-review; confirmed by lead reading of both code paths): encode with `reasoningEffort: .high`, one tool, history `[user, assistant(reasoning + text, no continuation part), user]` → `invalidRequest: "DeepSeek thinking with tools requires the original plaintext reasoning continuation."` Same result for a text-only assistant turn without a continuation.
- Remediation: require the continuation only for assistant turns whose function calls are still being answered in the current tool loop (the case where DeepSeek needs reasoning replay), and replay other assistant turns as text plus `function_call` items; alternatively generate a continuation on the incomplete path. Add a fixture regression: incomplete turn followed by a new user turn must encode. Update the guide either way. DeepSeek's exact upstream rule needs confirmation, but the SDK-side dead-end is confirmed regardless.
- Blocks RC.2 preparation: No. Fix or explicitly document as a known limitation before the rc.2 tag; DeepSeek currently claims fixture-only qualification.

### FABLE-RC2-002 — P3 — OpenAI refusal detection keyed on event type rather than part kind

- Path: `Sources/AgentProviders/OpenAIResponsesStreamDecoder.swift:153-155, 166-168` (refusal flag set only on `response.refusal.delta` / `response.refusal.done`); part acceptance at `:282-301, 405-427, 469-498`
- Problem: a refusal content part delivered via `content_part.added` + `content_part.done` + `output_item.done` without refusal delta events is accepted and completes with `stopReason = .endTurn`, so Core reports `.completed` instead of `.refused`.
- Impact: misclassified outcome only; content is still the refusal text; nothing executes. Documented OpenAI streams emit the delta/done events, so live exposure is low.
- Reproduction: fixture-reproduced by the provider sub-review with the event sequence above.
- Remediation: derive the refusal flag from any accepted part of kind `.refusal` in the seed/announce/reconcile paths; add the fixture.
- Blocks RC.2 preparation: No.

### FABLE-RC2-003 — P3 — Provider route honours an unbounded server `Retry-After`

- Path: `Sources/AgentProviders/ModelProviderRoute.swift:141-143` (`Task.sleep(for: retryAfter)`); `Sources/AgentProviders/ProviderHTTPFailure.swift:15-17`
- Problem: `Retry-After` is parsed with `Int` and `Duration.seconds(Int)`, so it cannot trap (unlike the Jev `Double` path fixed in `6ed5884`), but any non-negative value is slept on when `maxRetriesPerProvider > 0`.
- Impact: a hostile or misconfigured endpoint can park a Run until the caller's cancellation or deadline fires. Correctness of settlement is unaffected.
- Reasoning: verified by reading; no reproduction needed.
- Remediation: cap the honoured delay (for example, a documented maximum or the Run deadline) and add a fixture with an absurd `Retry-After`.
- Blocks RC.2 preparation: No.

### FABLE-RC2-004 — P3 — `DeepSeekReasoningEffort` is a closed public enum, inconsistent with the OpenAI extensible pattern

- Path: `Sources/AgentProviders/DeepSeekResponsesProvider.swift:8-13` versus `Sources/AgentProviders/OpenAIResponsesProvider.swift:8-18`; policy text at `docs/guides/swift-agent-versioning.md:57-61`
- Problem: the type is new since rc.1 and not yet released, so changing it now costs nothing, while adding a vendor value after rc.2 is a documented source break for exhaustive client switches. It also names wire value `"none"` as `case none`; the parameter is non-optional today (`:38`, default `.high`) so no `Optional.none` ambiguity exists, but any future optional property of this type reintroduces it. Two adapters in one module now follow divergent conventions.
- Impact: a routine vendor addition forces a major-version bump or a documented break.
- Remediation (explicit adjudication): convert to a `RawRepresentable, Hashable, Sendable, Codable` struct before the rc.2 freeze, mirroring `OpenAIReasoningEffort` (`disabled`/`low`/`high`/`max`), validate a trimmed non-empty raw value at provider init, keep fail-closed behaviour for unknown values (server rejects → `invalidRequest`), and update `versioning.md:57-64`. The existing `!= .none` comparisons at `DeepSeekResponsesProvider.swift:93` and `RequestEncoder.swift:32` keep working. The documented source-breaking policy is an acceptable fallback but unnecessary.
- Blocks RC.2 preparation: No.

### FABLE-RC2-005 — P3 — Stale public-symbol counts in two policy documents

- Path: `docs/guides/swift-agent-versioning.md:63-64` ("adds 57 precise public symbol identifiers"); `docs/releases/next-rc-development.md:20-22` ("1,013 public member symbols and 105 top-level types … 57 additions"); `docs/reviews/2026-09-18-swift-agent-public-api-audit.md:397-398` still carries the older numbers alongside the updated section.
- Problem: the measured and separately documented state is 1,151 symbols, 121 top-level types, 195 additions, 0 removals (`docs/reviews/2026-09-19-swift-agent-public-api-members.md:7-8,25`; confirmed by this review's symbol-graph diff).
- Impact: release-gate readers receive contradictory inventory claims.
- Remediation: update the three locations or replace hard-coded counts with a link to the generated inventory.
- Blocks RC.2 preparation: No.

### FABLE-RC2-006 — P3 — Every durable journal append re-reads and decodes the whole file (optimization follow-up)

- Path: `Sources/AgentCore/AgentJournal.swift:1145-1160` (`commit`), read path `:1251-1347`; same pattern in `persist` and `compactIfNeeded`; compaction threshold `:293`
- Problem: under the file lock each append performs a full `Data(contentsOf:)`, CRC and JSON decode of every frame, then a deep `Equatable` compare of all records before writing one frame. Cost is O(journal size) per tool result or checkpoint, cumulatively quadratic until compaction at 32 MB; checkpoint frames can carry up to 16 MB of history.
- Impact: latency only. The concurrent-writer check is what provides crash safety, so this is a correctness-adjacent performance risk, not a correctness defect. Pre-existing in rc.1.
- Remediation: compare a cheap fingerprint (valid length plus last-frame CRC/sequence) or cache the validated length between commits.
- Blocks RC.2 preparation: No.

### FABLE-RC2-007 — P3 — Two negative concurrency assertions rely on fixed sleeps

- Path: `Tests/AgentCoreTests/AgentIsolationTests.swift:78` and `:138` (80 ms sleep, then assert the replacement Run's provider has not started)
- Problem: a regression that starts the second worker late could land after the window on a loaded host and pass falsely.
- Impact: potential false-green for an isolation regression; no product defect.
- Remediation: replace the sleeps with a deterministic gate (`ToolScheduler.waitUntilPendingWaiterCountEquals`, `ToolScheduler.swift:24`, or an inverted bounded `providerProbe.waitUntilStarted`). `AgentMutationRecoveryTests.swift:466` is safe because both sides use `ContinuousClock`.
- Blocks RC.2 preparation: No.

### FABLE-RC2-008 — P3 — `AgentDecisions` response values do not self-validate

- Path: `Sources/AgentDecisions/DecisionModels.swift:190, 215, 233, 267`
- Problem: public memberwise inits and `Codable` accept NaN, out-of-range probabilities, or a `selected` value outside the request; validation lives only in the Jev decoder.
- Impact: none on the security boundary (decisions have no execution authority); third-party providers or persisted values can carry invalid numbers. Carried from the SAI-055 review with the recorded disposition.
- Remediation: an additive `DecisionResponse.validate(against:)` helper after rc.2.
- Blocks RC.2 preparation: No.

### Observations recorded without a finding

- Per-delta `String` concatenation in all three stream decoders (`OpenAIResponsesStreamDecoder.swift:805-823`, `DeepSeekResponsesStreamDecoder.swift:470-482`, `AnthropicStreamDecoder.swift:186-196`) is quadratic in response length but bounded by `maximumOutputTokens`; optimization follow-up only.
- `AgentJournal.swift:1163-1176`: when the very first durable append succeeds but the directory sync fails, the frame is adopted in memory and the error propagates, with re-sync on the next commit. Conservative and covered by `testFirstDurableAppendFailsClosedWhenDirectorySyncFails`. In the `AgentSession` flow the first frame is never a mutation intent (`AgentSession.swift:112-119`). Worth one sentence in the journal docs; no change needed.
- Known follow-ups SAI-045 (queued follow-up), SAI-046 (tombstone retention; `.mutationAborted` frames survive compaction, `AgentJournal.swift:1206-1233`), SAI-050 (immutable historical byte fixtures): no new correctness evidence found; they remain non-blocking.

## Verdicts

### Architecture verdict: PASS
`Package.swift` and the actual `import` lines show `AgentCore` depends only on `AgentModels` and `AgentTools`. No Anthropic, OpenAI, DeepSeek, Apple, Jev, Workspace, Tingting, Otoha, or UI framework import exists anywhere in the core chain. `FoundationModels` appears only in `AgentAppleProvider` (guarded); `FoundationNetworking` only in `AgentProviders` and `AgentJevProvider` (guarded); `Crypto`/`Darwin`/`Glibc` only in `WorkspaceAgent`. No `@testable`, `@_exported`, or `@_implementationOnly` in `Sources/`. `AgentDecisions` and `AgentJevProvider` are leaf products that never appear in `AgentCore`, `AgentProviders`, `AgentLoop`, or `ModelProvider`. `DependencyGuard` covers all eight modules and asserts the resolved manifest matches its map, so a new target cannot bypass it (11/11 cases pass).

### Security/mutation verdict: INTACT
Verified from source, not from documents. Order: `ToolRegistry.prepare` (`ToolRegistry.swift:36-53`: completeness, identity, JSON, input schema) → `AnyAgentTool` invocation (`AnyAgentTool.swift:43-118`: admission and idempotency key → Evidence `:56` → authorization then Evidence re-check `:57-62` → durable intent `admit` `:66` → settled replay only with validated receipt and stored output `:77-88` → executor `:92` → receipt validation `:103-107`) → output schema (`ToolRegistry.swift:57-59`) → Evidence recorded only from tool results (`:62-65`). The isolation lease wraps the entire invocation (`ToolScheduler.swift:77-87`), which is stricter than the stated order. Settlement is `journal.commitMutation` (`AgentJournal.swift:641-672`), which re-validates the receipt against the durable intent and writes receipt, output, settled, and checkpoint in one frame. Failures after the executor mark `needsReconciliation` (`AgentToolBatchProgress.swift:71-76`, `AgentLoop.swift:181-187`); `admit` (`:1519-1562`) replays only `.settled` with matching name and canonical arguments and throws on `.intent`/`.needsReconciliation`; `recoverPendingMutations` (`:592-600`) only quarantines. `ToolReceiptValidator` (`ToolReceipt.swift:57-79`) accepts only `.succeeded` with exact targets. Nothing reachable from `ModelEvent`, conversation history, `.providerContinuation` content, or a `DecisionResponse` can mint Evidence, authorize, execute, construct a trusted receipt, or settle. Uncertain mutations never auto-replay.

### Concurrency/session verdict: SOUND
One active Run (`AgentSession.swift:59`), process-wide identity registry (`:334-345`), OS `flock` session lease (`AgentJournal.swift:404-444`), new Run awaits the previous physical drain (`:60-63`), logical completion separated from drain in `finish` (`:240-265`). The stale-compactor fix is real: `record` re-checks budget and `activeRunID` after the compactor and the journal append (`:203-223`), and `appendCheckpointForCurrentRun` (`AgentJournal.swift:516-534`) rejects a checkpoint for a Run that is no longer the session's latest. Completion reservation and blocked mutation commits are proven by `AgentCompletionCommitTests` (4 cases, also enforced by the concurrency seal). Late executor results after cancellation are discarded and quarantined because `withOperationDeadline` settles once. Route callbacks are generation-fenced (`ModelProviderRoute.swift:251-261`). Only weakness: the two sleep-based negative assertions in FABLE-RC2-007.

### Journal/restart verdict: SOUND
Versions 1, 2, 3 accepted (`AgentJournal.swift:295`); v1 intents without receipt expectations load as `needsReconciliation` (`:850`); per-frame CRC; terminal-frame corruption → `corruptTail` requiring explicit `discardCorruptTail`; short tail → `truncatedTail` repaired by the next append (`:1349`); lock and lease are both `flock`-based so a crashed writer cannot strand them; compaction is temp-write, fsync, atomic rename, directory sync, with `directorySyncPending` re-sync on the next commit (`:1120-1160`). The new directory-sync uncertainty handling for first append, snapshot publication, and compaction is conservative and tested. Tombstones survive compaction (SAI-046, known). FABLE-RC2-006 is a latency concern only.

### Provider verdict per adapter (fixture evidence unless stated)
- Anthropic: PASS. rc.1 delta is alias-aware model identity only (`AnthropicProvider.swift:42-72`, `AnthropicStreamDecoder.swift:66-71`); block/delta discipline, signature-after-thinking ordering, `redacted_thinking` retained, server-tool blocks rejected, usage overflow-checked.
- OpenAI Responses: PASS with P3 (FABLE-RC2-002). Strictly increasing `sequence_number`; items unique by `output_index` and `id`; every delta bound to item/part; prefix-checked reconciliation at part done, item done, and final output; `arguments.done` → `item.done` → final output as independent required transitions; hosted tools and unknown item types rejected; `encrypted_content` consistency enforced; exact/alias model identity; classified, sanitized stream errors; `store: false`, no `previous_response_id`.
- DeepSeek Responses: PASS with P2 (FABLE-RC2-001). Same stream discipline; `.developer` rejected before I/O; hosted/custom tools rejected; omitted status accepted, `null` status rejected; tool-name validation; reasoning required for completed tool-enabled turns.
- Apple on-device: PASS. Host tools never registered natively (`AppleNativeGeneration.swift:44, 64`); plan validated against request tools with JSON-decodable arguments (`AppleFoundationProvider.swift:57-63`); fresh call IDs; execution stays in Core.
- Apple PCC: PASS on compile and fixture evidence; gated by `compiler(>=6.4)` and macOS/iOS 27; refusal/guardrail → `.refusal`, quota → `.rateLimited` with `retryAfter`; live evidence is operator opt-in only.
- Routing/fallback: PASS with P3 (FABLE-RC2-003). Namespace and capability checks, generation-fenced validated-candidate recording, pinned candidate after the mutation boundary with `fallbackBlocked` (`ModelProviderRoute.swift:166-201`), attempts bounded by policy, events buffered and accumulator-validated before emission.
- Transport/SSE: ephemeral session, no cache/cookies/credential storage, redirects refused, per-event 1 MiB cap (`ProviderSSEDecoder.swift:17-34`), UTF-8 validated, unterminated frame rejected. Jev `Retry-After` overflow trap is fixed (`6ed5884`) and verified at boundaries in the SAI-055 follow-up.

### Continuation verdict: PASS
All three continuations are opaque, bound to provider id, model name, and format version, exactly one per assistant message. Restore verifies canonical visible text and reasoning totals, ordered visible-content binding (v2), and call identity/arguments; split kind runs are rejected; legacy v1 payloads migrate (`OpenAIResponsesContinuation.swift:187-226`). Checkpoint → restart → next request: Core replays canonical history; the continuation only changes what the provider is asked to replay, and a tampered payload fails closed as `invalidRequest`. A continuation is never Evidence, authorization, or a receipt, and cannot influence admission or settlement.

### Decision/Jev isolation verdict: PASS
`AgentDecisions` depends on `AgentModels` only; `AgentJevProvider` on `AgentModels` and `AgentDecisions`. Neither is imported by `AgentCore`, `AgentProviders`, or `AgentLoop`; `DecisionProvider` is not a `ModelProvider` and has no executor, Evidence, Receipt, journal, or admission surface. `certainDecisionCannotBypassEvidenceOrReachMutationExecutor` shows a probability-1 decision still ends in `EvidenceError` with zero executions. Jev credentials never appear in descriptions, reflection, or errors; endpoint restricted to HTTPS or loopback HTTP without credentials/query/fragment; redirects refused.

### Public API verdict: COMPATIBLE, with an explicit `DeepSeekReasoningEffort` recommendation
Symbol-graph diff rc.1 → candidate: 956 → 1,151 public symbols, 195 additions, 0 removals, 0 declaration changes, no new requirements on any rc.1 public protocol, no default-argument changes on rc.1 initializers. The added Anthropic and OpenAI initializers differ only by the non-defaulted `resolvedModelIDsByAlias`, so rc.1 call shapes remain unambiguous. Regrettable surfaces: `DeepSeekReasoningEffort` as a closed enum (FABLE-RC2-004) and non-validating decision response values (FABLE-RC2-008). **Recommendation: convert `DeepSeekReasoningEffort` to an extensible `RawRepresentable` struct before the rc.2 freeze.** It is unreleased, the OpenAI adapter in the same module already uses that pattern, the adapter can still fail closed on unknown values, and doing it after rc.2 would itself be a source break. Keeping the closed enum with the documented source-breaking policy is acceptable only if the team explicitly prefers compile-time exhaustiveness over vendor-value additivity; in that case rename `none` to avoid the Optional footgun.

### Test/portability verdict: PASS with P3 test-robustness notes
No skipped or disabled non-live tests; five live tests are env-gated and skip in CI. No false-green found: negative fixtures assert error kinds, and both Responses adapters have tamper and terminal-state matrices. Timing: two upper-bound negative assertions (FABLE-RC2-007); provider timing assertions use lower bounds or bounded polling. Missing regressions: FABLE-RC2-001 (encode after an incomplete DeepSeek turn), FABLE-RC2-002, a retry-delay cap. Portability: `#if canImport(FoundationNetworking)` present in every URLSession user; no Darwin-only API in portable targets (`fsync`/`flock` via `@_silgen_name`); `Scripts/ci-linux.sh` builds the six portable targets, verifies WorkspaceAgent and AgentAppleProvider are not compiled, and runs the full suite plus ExternalClient; iOS 16 cross-build of the portable targets succeeds; ExternalClient uses public products only. Linux was not executed in this review.

### Residual live qualification gaps
- OpenAI: `include: reasoning.encrypted_content` on non-reasoning models; real multi-turn replay of `OutputMessage` items with native `id`/`status`; live refusal stream shape.
- DeepSeek: no live qualification claimed anywhere; tool loops, incomplete turns, and reasoning replay are fixture-only.
- Anthropic: live tests exist but are opt-in; alias-to-dated-ID mapping verified against fixtures only.
- Apple PCC: quota and availability paths have compile/fixture evidence only.
- Jev: live `POST /v1/systemone` never executed; OpenAPI document hash verified.
- Linux: `flock` lease/lock behaviour, URLSession redirect refusal, and the full suite rely on `ci-linux.sh`, not executed here.

### Overall verdict: READY FOR RC.2 RELEASE PREPARATION
No P0 or P1 exists. The security and mutation boundary is intact from source inspection, the session/journal changes are sound and tested, the public API is additive with zero removals, and all builds and suites pass on the candidate commit. Before the rc.2 tag is authorized: resolve or explicitly document FABLE-RC2-001 (DeepSeek dead-end), decide FABLE-RC2-004 (`DeepSeekReasoningEffort`), and correct the stale counts in FABLE-RC2-005. The remaining P3 items and the live qualification gaps can be deferred with the existing opt-in policy.
