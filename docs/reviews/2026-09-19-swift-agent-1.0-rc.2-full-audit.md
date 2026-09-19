# SwiftAgent 1.0.0-rc.2 Full Audit

> last-verified: 2026-09-19
>
> Status: final hosted and Host integration evidence pending. This document is
> updated on the exact candidate before the release gate closes.

## Baseline And Scope

- Published anchor: annotated `1.0.0-rc.1` tag object
  `2699d9f68264ca8432ee11a5ef819b9264b8ef2f`, dereferenced to
  `d2347f11c6a78f421708e897dae42a51a98d37ea`.
- Audit start: `9be07d50c1c276c77661856694d1a30f4e77ad48` on
  `plan/swift-agent-rc2`.
- Audited delta: all source, tests, examples, scripts, and documentation from
  rc.1 through the final candidate, not only the last remediation commit.
- Release actions are out of scope: no tag, GitHub Release, or merge to `main`.

## Gate Results

| Area | Result | Current evidence |
| --- | --- | --- |
| Architecture | PASS | Manifest graph and `ArchitectureTests`; Core imports only Models and Tools. Provider, Apple, Decision/Jev, Workspace, Tingting, and UI frameworks remain outside Core. |
| Security | PASS | Model/conversation/continuation/Decision output cannot create Evidence, authorize a tool, execute a mutation, create a trusted Receipt, or settle a Journal. |
| Mutation | PASS | Durable intent precedes executor; receipt is validated before atomic settlement; cancellation, failure, restart, fallback, and retry never auto-replay uncertain effects. |
| Journal | PASS | v1/v2/v3 load, CRC/frame validation, corrupt/truncated tail, locks, leases, atomic compaction, stale writer, settlement replay, reconciliation, and abort are covered. |
| Concurrency | PASS | One active Run, identity lease, logical terminal vs physical drain, compactor ownership, completion reservation, route generation fence, and cancellation waiter ownership are deterministic. |
| Context / Session / Run | PASS | Canonical history, current instructions, steering, tool-pair protection, restart, compaction, late callback rejection, and drain semantics retain their frozen contract. |
| OpenAI Responses | PASS | Fixture evidence covers text, tools, structured output, encrypted reasoning continuation, refusal, usage, aliasing, SSE identity/order/terminal rules, cancellation, typed failures, and mutation fencing. |
| DeepSeek Responses | PASS | Stateless replay, plaintext reasoning, tools, incomplete/item status, usage, aliases, cancellation, and typed failures are covered. Incomplete turns no longer poison later Runs. |
| Anthropic | PASS | Existing full regression suite, signed continuation, thinking/tool order, SSE terminal validation, error mapping, cancellation, and alias identity pass. |
| Apple / PCC | PASS | Compile and deterministic fixtures pass; AgentCore remains the only host-tool execution authority. Live on-device/PCC qualification is operator opt-in. |
| Decision / Jev | PASS | Products stay outside AgentCore/AgentLoop; strict Jev identity/range/usage/metadata validation and cancellation pass; a certain Decision still cannot bypass Evidence. |
| Public API | PASS | Swift 6.4 symbol graphs: 956 → 1,156 precise identifiers, +200 / -0; 100 → 121 top-level types. No rc.1 public symbol is removed. |
| Linux | PASS | Swift 6.4 clean-copy container runs six portable target builds, 126 XCTest, 437 Swift Testing, 2 live skips, ExternalClient 7/7, and target-isolation checks. |
| ExternalClient | PASS | 7/7 through public imports only, including standard Agent, durable mutation/idempotency, recoverable error, and Decision/Jev consumption. |
| Hosted CI | PENDING | Must pass on the exact final audit-seal SHA with non-empty macOS, Linux, and Apple jobs. |
| Tingting Host | PENDING | Final pushed child SHA must be committed as the parent gitlink and pass focused Host/macOS/iOS validation plus recursive-clone identity. |

## Security And Recovery Invariants

The audited execution order remains:

```text
schema
→ Evidence
→ authorization
→ resource isolation
→ durable mutation intent
→ Host executor
→ Receipt validation
→ durable settlement
```

An executor result without a durable settlement is uncertain and requires
reconciliation. A settled idempotent replay reuses the original durable output
and Receipt without invoking the executor. Provider continuation is opaque
optimization state bound to provider/model/canonical visible content and tool
identity; it is not conversation truth, Evidence, authorization, or Receipt.
Decision responses are proposals outside AgentLoop and have no execution or
journal capability.

## Provider Qualification

- OpenAI, DeepSeek, Anthropic, Apple/PCC, and Jev have deterministic fixture,
  package, and hosted-build gates.
- Credentialed live tests are intentionally opt-in and were not run in this
  audit: Anthropic, OpenAI, DeepSeek, Apple on-device/PCC, and Jev.
- DeepSeek live gaps remain explicitly unqualified: whether live tool streams
  emit `response.function_call_arguments.done`, native metadata replay shape,
  and incomplete final item-status shape.
- Provider-hosted tools remain outside `AgentTool` and are rejected when the
  adapter cannot preserve the host-executed safety contract.

## Public API Audit

`DeepSeekReasoningEffort`, new after rc.1, was changed before rc.2 freeze from a
closed enum to an extensible validated raw-value structure. Named values are
`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`; future non-empty
wire values remain representable. The final module counts are:

| Module | rc.1 | Candidate | Delta |
| --- | ---: | ---: | ---: |
| AgentAppleProvider | 5 | 7 | +2 |
| AgentCore | 283 | 283 | 0 |
| AgentDecisions | 0 | 131 | +131 |
| AgentJevProvider | 0 | 7 | +7 |
| AgentModels | 260 | 260 | 0 |
| AgentProviders | 41 | 101 | +60 |
| AgentTools | 311 | 311 | 0 |
| WorkspaceAgent | 56 | 56 | 0 |
| **Total** | **956** | **1,156** | **+200** |

## Independent Review And Findings

Claude Fable 5.1 independently reviewed rc.1 → audit start, then performed a
read-only remediation review through `d700921050a39020ce0910a88f454f6903d53c43`.
The prompts and verbatim reports are committed beside this audit.

| ID | Severity | Disposition | Result |
| --- | --- | --- | --- |
| FABLE-RC2-001 | P2 | Accepted | DeepSeek incomplete-turn session poisoning reproduced and fixed in `24a5f98`; two-Run regression passes. |
| FABLE-RC2-004 | P3 | Accepted | Closed DeepSeek effort enum replaced by extensible raw-value type in `acc62ff`. |
| FABLE-RC2-007 | P3 | Accepted | Two 80 ms isolation sleeps replaced by an internal deterministic drain-wait observation in `d700921`. |
| FABLE-RC2-005 | P3 | Accepted | Symbol counts and enum policy corrected to 1,156 / 121 / +200 / -0. |
| FABLE-RC2-002 | P3 | Deferred | OpenAI refusal-without-delta classification tracked by SAI-062. |
| FABLE-RC2-003 | P3 | Deferred | Direct-route Retry-After cap tracked by SAI-063; AgentLoop deadline and cancellation already bound Runs. |
| FABLE-RC2-006 | P3 | Deferred | Journal append performance tracked by SAI-064; no recovery/correctness defect found. |
| FABLE-RC2-008 | P3 | Deferred | Additive generic Decision validation tracked by SAI-065; Jev validates before publication and Decisions have no authority. |

The remediation review reports P0 0, P1 0, P2 0 and no new finding.

## Local Verification

| Command | Toolchain / platform | Discovered / passed / skipped | Exit |
| --- | --- | --- | ---: |
| `bash Scripts/ci-macos.sh` | Swift 6.4, Xcode 27, macOS 27 | 126 XCTest; 447 Swift Testing; 5 live/provider skips; ExternalClient 7/7; iOS 16 cross-build | 0 |
| `bash Scripts/ci-concurrency-seal.sh` | Swift 6.4, macOS | ToolResourceCoordinator 11/11; AgentCompletionCommit 4/4 | 0 |
| `bash Scripts/ci-apple-provider.sh` | Swift 6.4, Xcode 27 | 18 discovered; 15 passed; 3 live skipped | 0 |
| `bash Scripts/ci-linux.sh` in clean `swift:6.4` container | Swift 6.4, Linux aarch64 | 126 XCTest; 437 Swift Testing; 2 live skips; ExternalClient 7/7; Core isolation pass | 0 |

## Residual Risks

- Post-RC product/API work: SAI-045 queued follow-up.
- Post-RC durability work: SAI-046 tombstone retention and SAI-050 immutable
  historical journal byte fixtures.
- Post-RC audit findings: SAI-062 through SAI-065.
- Live qualification gaps are not replaced by fixture or hosted CI evidence.
- SSE string accumulation and journal append validation have measured/design
  follow-ups, but no release-blocking correctness evidence.

## Release Gate

Final verdict is written only after exact-SHA hosted CI and Tingting Host
integration complete. `READY FOR RC.2 RELEASE PREPARATION` does not authorize a
tag, GitHub Release, merge to `main`, or Host publication.
