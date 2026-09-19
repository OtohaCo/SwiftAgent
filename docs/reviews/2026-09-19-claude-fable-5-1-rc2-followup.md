# SwiftAgent RC.2 follow-up review (SAI-061 remediation)

> Independent reviewer output, preserved verbatim. The documentation inventory
> noted as stale below was corrected after this committed-code review; the final
> counts are 1,156 symbols, 121 top-level types, 200 additions, and 0 removals.

- Reviewer model/runtime: Claude Fable 5.1 (`claude-fable-5-1`)
- Repository: `/Users/lilong/Works/Tingting/SwiftAgent`, branch `plan/swift-agent-rc2`
- Release anchor: `d2347f11c6a78f421708e897dae42a51a98d37ea` (`1.0.0-rc.1`)
- Prior full-review candidate: `9be07d50c1c276c77661856694d1a30f4e77ad48`
- Reviewed remediation candidate: **`d700921050a39020ce0910a88f454f6903d53c43`** (`d700921`)
- Date: 2026-09-19
- Mode: read-only. The candidate was exported with `git archive` to `/tmp/swiftagent-sai061-d700921`; no file, index, branch, tag, or worktree change was made in the repository. Reviewer-only probe tests were written only in the scratch export and deleted; the export was removed afterwards.
- Note: at the end of this review the working tree showed uncommitted modifications to `docs/guides/swift-agent-versioning.md`, `docs/releases/next-rc-development.md`, and `docs/reviews/2026-09-18-swift-agent-public-api-audit.md`. They are not mine and were not reviewed; only the committed `d700921` tree was assessed. They appear to target FABLE-RC2-005 below.

## Delta 9be07d5..d700921

Three commits: `acc62ff` (extensible `DeepSeekReasoningEffort`), `24a5f98` (preserve DeepSeek sessions after incomplete turns), `d700921` (deterministic drain isolation tests). Ten files, +146/−18. Production changes are confined to `Sources/AgentCore/Agent.swift`, `Sources/AgentCore/AgentSession.swift`, `Sources/AgentProviders/DeepSeekResponsesProvider.swift`, and `Sources/AgentProviders/DeepSeekResponsesRequestEncoder.swift`. No other source file changed, so the OpenAI decoder, `ModelProviderRoute`, `AgentJournal`, and `AgentDecisions` are byte-identical to the previously reviewed candidate.

## Commands run (candidate export, Swift 6.4 / Xcode 27.0 / macOS 27)

```
git rev-parse d700921
git log --oneline 9be07d50..d700921
git diff --stat 9be07d50..d700921
git diff 9be07d50..d700921 -- Sources Tests docs CHANGELOG.md
git archive d700921050a39020ce0910a88f454f6903d53c43 | tar -x -C /tmp/swiftagent-sai061-d700921
swift build --disable-sandbox                                   # clean, no warnings
swift test --disable-sandbox --no-parallel                      # exit 0
swift test --disable-sandbox --no-parallel --filter "AgentIsolationTests"   # 8 consecutive runs, all 4/4 pass
swift test --disable-sandbox --no-parallel --filter "ReviewDeepSeekPoisonTests"  # reviewer-only probe, 2/2 pass, then deleted
swift build --disable-sandbox --target AgentProviders -Xswiftc -emit-symbol-graph ... -symbol-graph-minimum-access-level public
```

Full-suite result: Swift Testing 168 + 134 + 84 + 24 + 18 + 10 + 9 tests and XCTest 56, 30, 29, 28, 26, 21, 11, 10, 8, 5, 4, 3, 2 across targets; 0 failures; the same 5 credentialed live tests skipped by policy. `AgentProvidersTests` grew from 131 to 134 (the three new regressions). Live provider calls were not made; DeepSeek documentation was fetched read-only to verify effort vocabulary.

## Resolution of the three targeted findings

### 1. P2 (FABLE-RC2-001) DeepSeek thinking+tools poisoning after an incomplete turn: RESOLVED

- Fix: `Sources/AgentProviders/DeepSeekResponsesRequestEncoder.swift:32` now throws only when `reasoningEffort != .none && !request.tools.isEmpty && !calls.isEmpty`. An assistant turn without a continuation and without tool calls is replayed as plain assistant text (reasoning parts are dropped by `text(_:)` at `:102-110`).
- Why this is sufficient: `AgentLoop.swift:146-160` checkpoints every non-`toolCalls` terminal response with `checkpointContent(response, retainingToolCalls: 0)` and `toolCalls: []`, so a Core-produced incomplete turn never carries calls into canonical history. The only continuation-less assistant turns that still fail closed are those with tool calls, which can only originate from host-edited or foreign history, and those are exactly the turns for which DeepSeek requires plaintext reasoning replay.
- Shipped regression: `incompleteTextTurnDoesNotPoisonTheNextRunWhenToolsRemainAvailable` (`Tests/AgentProvidersTests/DeepSeekResponsesIncompleteTests.swift:56-94`) runs two Runs through `Agent`/`AgentSession` with a registered tool, asserts `.incomplete(.maxOutputTokens)` then `.completed`, zero executions, and that the second request replays `"Partial answer"` as an assistant message. Recorded in `docs/testing-regressions.md:41`.
- Reviewer probe (deleted afterwards), two additional cases:
  - Incomplete turn containing a partial `function_call` plus partial reasoning, then a second Run with the tool still registered: first outcome `.incomplete(.maxOutputTokens)` with one incomplete proposal, second outcome `.completed`, executions 0, and the second request body contained no `function_call` and no `reasoning` item (input was the two user messages only, because the dropped proposal left no visible text).
  - Host-edited history with an assistant tool call, its tool result, and no continuation: `encode` throws `ModelProviderError` with `reasoningEffort: .high` and encodes with `.none`. Fail-closed behaviour for tool-call turns is unchanged.
- Fail-closed continuation checks: untouched. `DeepSeekResponsesContinuation.restore` is still attempted first (`RequestEncoder.swift:27-30`); tamper, reorder, split-run, and identity validation live in the continuation and were not modified. `deepSeekThinkingWithToolsRejectsPlainTextWithoutReasoningInSameTurn` still passes, so a completed thinking+tools turn without reasoning is still rejected at decode time.
- Documentation: `docs/guides/swift-agent-deepseek-provider.md:85-89` and `CHANGELOG.md:25-27` describe the new behaviour accurately.
- Residual: no fixture or live evidence that DeepSeek accepts a plain assistant text item without reasoning in a thinking+tools conversation; this was already the documented fixture-only qualification boundary and is not a regression.

### 2. P3 (FABLE-RC2-004) closed `DeepSeekReasoningEffort` enum: RESOLVED

- `Sources/AgentProviders/DeepSeekResponsesProvider.swift:7-28`: now a `RawRepresentable, Hashable, Sendable, Codable` struct with static `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, and single-value `Codable`, mirroring `OpenAIReasoningEffort`. Provider construction rejects empty or untrimmed raw values (`:62-65`). The `!= .none` comparisons at `:112` and `RequestEncoder.swift:32` keep working through `Hashable`.
- Vocabulary check: DeepSeek's thinking-mode guide (fetched 2026-09-19) documents the Responses-API `reasoning.effort` values `none/low/high/max` and a normalization table accepting `minimal`, `medium`, `xhigh`, and `ultra`. Every named static is a documented value; `ultra` is reachable through `init(rawValue:)`. The guide text at `docs/guides/swift-agent-deepseek-provider.md:30-33` is accurate.
- Public API compatibility: `DeepSeekReasoningEffort` did not exist at rc.1 (no DeepSeek source in `d2347f11`), so the enum-to-struct change removes no rc.1 symbol. Relative to `9be07d5` it replaces the enum and its four case symbols with the struct and its members. The `AgentProviders` public symbol graph at `d700921` has 101 symbols (16 for this type). Tests: `reasoningEffortAcceptsAndPreservesFutureWireValues` and `invalidReasoningEffortFailsDuringProviderConstruction` (`DeepSeekResponsesProviderTests.swift:49-82`).
- Residual note (not a finding): keeping the name `none` reproduces the `Optional.none` ambiguity if any future API takes `DeepSeekReasoningEffort?`. The current parameter is non-optional with default `.high`, so nothing is affected today.

### 3. P3 (FABLE-RC2-007) sleep-based negative assertions in `AgentIsolationTests`: RESOLVED

- `Sources/AgentSession.swift:26, 35-36, 48, 63-64` add an internal `drainWaitDidBegin` hook fired when a new Run starts waiting on the previous physical drain; `Agent.swift:88-107` threads it through an internal `makeSession` overload with defaults. The public `makeSession(id:journal:)` signature is unchanged; the hook is internal and reached only via `@testable import AgentCore` in `Tests/AgentCoreTests/AgentIsolationTests.swift:6`.
- Both tests now wait on an `XCTestExpectation` fulfilled by the hook (`:69, :79` and `:129, :140`) instead of an 80 ms sleep. The assertion "provider labels are still `["A"]`" is deterministic because the hook fires before `await pendingDrainTask.value`, and the drain cannot complete until the test releases its gates.
- Determinism evidence: 8 consecutive filtered runs, 4/4 tests passing each time.
- Cancellation/drain semantics: the only behavioural addition is a non-throwing callback before the existing `await pendingDrainTask.value` / `Task.checkCancellation()` pair (`AgentSession.swift:63-66`); ordering of drain wait and cancellation check is unchanged. Concurrency seal suites (`ToolResourceCoordinatorTests` 11, `AgentCompletionCommitTests` 4) still pass within the full run.

## No weakening of adjacent guarantees

- Tool execution: `AgentLoop`, `AnyAgentTool`, `ToolRegistry`, `ToolScheduler`, and `AgentJournal` are unchanged; the probe shows incomplete proposals never execute (executions 0) and are never replayed.
- Continuation: no continuation source changed; restore still runs first and tampering still fails closed.
- Public API: no rc.1 symbol removed or changed; the only surface change is the unreleased `DeepSeekReasoningEffort`, now aligned with the OpenAI pattern.
- Provider neutrality: `AgentCore` changes are provider-agnostic test hooks; no vendor import entered `AgentCore`.

## Re-evaluation of the remaining prior P3 findings

| ID | Finding | State at d700921 | Classification | Evidence |
| --- | --- | --- | --- | --- |
| FABLE-RC2-002 | OpenAI refusal part without refusal delta reports `.completed` instead of `.refused` | Unchanged (`OpenAIResponsesStreamDecoder.swift` not in delta) | Post-RC follow-up | Misclassified outcome only; refusal text is still the visible content; nothing executes. Documented OpenAI streams emit `response.refusal.delta/done`, so live exposure is low. |
| FABLE-RC2-003 | `ModelProviderRoute` sleeps for an unbounded `Retry-After` | Unchanged (`ModelProviderRoute.swift:141-143`, `ProviderHTTPFailure.swift:15-17`) | Post-RC follow-up | `Int` parsing cannot trap; effect is a Run parked until the caller's cancellation or `runTimeout` deadline, which remain effective. Only reachable with `maxRetriesPerProvider > 0` and a hostile or misconfigured server. Recommend a documented cap. |
| FABLE-RC2-006 | Journal append re-reads and decodes the full file | Unchanged (`AgentJournal.swift:1145-1160`) | Post-RC follow-up | Pre-existing in rc.1; latency only; crash-safety is provided by that same check. |
| FABLE-RC2-008 | `AgentDecisions` response values do not self-validate | Unchanged (`DecisionModels.swift:190, 215, 233, 267`) | Post-RC follow-up | Decision output has no execution authority; the Jev adapter validates before publishing; an additive `validate(against:)` can ship later without breaking the API. |
| FABLE-RC2-005 | Stale public-API counts in policy docs | Unchanged and now slightly more stale | Post-RC follow-up (documentation only; recommended before the tag, not blocking) | `docs/guides/swift-agent-versioning.md:59-64` still says "57 identifiers" and calls `DeepSeekReasoningEffort` "intentionally a closed enum"; `docs/releases/next-rc-development.md:20-22` still says 1,013 / 105 / 57; `docs/reviews/2026-09-19-swift-agent-public-api-members.md:33-37, 605-616` still lists the type as an enumeration with case symbols and `AgentProviders` at 96 symbols, whereas the measured graph is 101. |

## Findings at d700921

- P0: none.
- P1: none.
- P2: none. FABLE-RC2-001 is resolved.
- P3: the five items in the table above remain open as post-RC follow-ups. No new finding was introduced by the remediation.

## Verdict

**No open RC blocker remains.** The P2 DeepSeek session-poisoning defect is fixed at the correct layer with a shipped regression and holds for the partial-tool-call variant; the `DeepSeekReasoningEffort` type is now extensible and consistent with the OpenAI adapter without touching any rc.1 symbol; the isolation tests are deterministic. Fail-closed continuation, tool execution, cancellation/drain, public API compatibility, and provider neutrality are unchanged. The stale documentation counts (FABLE-RC2-005) are the one item worth correcting before the rc.2 tag because they contradict the generated inventory, but they do not affect code or release safety. Verdict: **READY FOR RC.2 RELEASE PREPARATION**, unchanged from the full review, now without a conditional P2.
