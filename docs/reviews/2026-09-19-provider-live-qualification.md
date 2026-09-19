# Provider Live Qualification

last-verified: 2026-09-20

## Scope and revisions

This report records a bounded local operator run. It is not ordinary CI and it
does not qualify every model or service deployment.

- Audit baseline: `85ea79767f3782e3c98c339e3efc8bb150582680`
- DeepSeek remediation: `a77b7f9` (`SAI-068 fix DeepSeek live continuation replay`)
- Live-run executable examples: `fb331d0999c9b116c41c814186e6cb32c45aeeb7`
- Post-run evidence/budget hardening: `1153770c7923bc7742792bd0196946db152c50c5`
- Independent-review remediation: `048a6700eb0ccb59264d825ee88391d5e956abab`
- Fixture-preflight isolation: `14c60ae2853242378e626d55c7c0b7bfe3866f96`
- Fixture-run endpoint isolation: `c17adeb86f5ea086e9ac9f2d454a41fbe7f85455`
- Compiler/runtime: Apple Swift 6.4, macOS 27.0
- Concurrency: one live process at a time
- Limit: 12 HTTP sends per provider, 48 total
- Actual sends: OpenAI 10, DeepSeek 12, Anthropic 10, Jev 4; 36 total

The persistent budget ledger contained counts only and was permission-restricted.
Credentials came from an operator-owned literal assignment file. The examples
reported only `CONFIGURED` or `MISSING`; they did not print secret values,
lengths, hashes, request bodies, response text, signatures or opaque
continuation values. No live mode fell back to a fixture.

After the bounded service run, the qualification harness was hardened to require
the persistent ledger for every live request, verify exact current-call/result
binding, and make the restart fixture execute a real local read-only tool before
reloading the durable journal. Those checks passed offline, but they do not
retroactively convert the earlier text-history live runs into durable-tool
restart evidence.

Independent review then added cross-process ledger serialization, explicit-only
environment-file selection, complete `all`/cancellation fixtures, and fail-closed
AppleChatApp argument/error handling. These changes affect future operator runs;
they did not send another cloud request or reset the recorded budget.

The final fixture regressions prevent offline fixture mode from reading or
rendering live endpoint, model or credential status, including malformed live
endpoint values during non-preflight fixture cases. Budget lock artifacts are
also ignored. The focused qualification package passed 22 tests in five suites;
this local-only hardening sent no cloud request.

## Results

| Provider/service | Model | Case | Result | Evidence |
| --- | --- | --- | --- | --- |
| OpenAI-compatible gateway | `gpt-5.6-luna` | Two-turn text | PASS | Two sends; second request contained committed assistant history; cumulative usage input 8,851, output 30, reasoning 9 |
| OpenAI-compatible gateway | `gpt-5.6-luna` | Read-only tool | PASS | Two sends; one proposed call, one Host execution, current call/result binding in the second request; usage input 4,502, output 10 |
| OpenAI-compatible gateway | `gpt-5.6-luna` | Text-history restart | PASS | Durable journal reloaded under the same Session identity and the second request contained committed assistant history; usage input 8,853, output 30, reasoning 10 |
| OpenAI-compatible gateway | `gpt-5.6-luna` | Durable tool-history restart | NOT RUN_BUDGET | The hardened case requires up to three sends; only two OpenAI sends remained after the bounded run. Fixture coverage proves one pre-restart execution and no post-restart re-execution |
| OpenAI-compatible gateway | `gpt-5.6-luna` | Structured output | PASS | One send; complete terminal JSON passed Host validation; usage input 4,434, output 14 |
| OpenAI-compatible gateway | `gpt-5.6-luna` | Cancellation | PASS | Request was recorded as sent and response-started before `run.cancel()`; logical terminal and drain both completed |
| OpenAI official | configured key, no model | All live cases | BLOCKED_CONFIGURATION | Preflight reported the required model missing and sent no request |
| OpenAI encrypted reasoning continuation | gateway model | Cross-turn replay | NOT EXERCISED | No encrypted continuation was observed; gateway success is not official-endpoint evidence |
| Anthropic gateway | `claude-haiku-4-5-20251001` | Two-turn text | PASS | Two sends; committed assistant history entered the second request; usage input 1,145, output 400, reasoning 266 |
| Anthropic gateway | `claude-haiku-4-5-20251001` | Read-only tool | PASS | Thinking-enabled and thinking-disabled loops each executed the local Calculator once and bound the real result into the next request |
| Anthropic gateway | `claude-haiku-4-5-20251001` | Text-history restart | PASS | Two sends; the durable journal reloaded and the service accepted committed history with configured thinking/signed continuation |
| Anthropic gateway | `claude-haiku-4-5-20251001` | Durable tool-history restart | NOT RUN_BUDGET | The hardened case requires up to three sends; only two Anthropic sends remained. Fixture coverage proves one pre-restart execution and no post-restart re-execution |
| Anthropic gateway | `claude-haiku-4-5-20251001` | Structured output and usage | PASS | Complete structured output was Host-validated; cumulative usage remained provider-reported rather than reconstructed |
| Anthropic gateway | `claude-haiku-4-5-20251001` | Cancellation | PASS | The request started before cancellation and both logical terminal and physical drain completed |
| DeepSeek official | `deepseek-flash` | Completed reasoning/usage | PASS | Post-fix send emitted and accepted a complete ordered SSE response; usage input 50, output 18, reasoning 15 |
| DeepSeek official | `deepseek-flash` | Cancellation | PASS, PRE-FIX OBSERVATION | The request was sent and cancellation/drain completed. This unaffected path was not repeated after the continuation fix because the provider budget was exhausted |
| DeepSeek official | `deepseek-flash` | Text, tool, restart, structured | NOT RUN_BUDGET | The 12-send provider limit was reached while diagnosing and fixing real output-only reasoning metadata |
| DeepSeek official | `deepseek-flash` | Function argument/item-done, native metadata replay, incomplete status | NOT OBSERVED | The service did not provide enough post-fix budgeted evidence to claim these live shapes; fixture coverage remains |
| TypeSafe Jev official | `jev-latest` | Noul | PASS | Question identity and finite typed probability validated; usage input 285, output 20 |
| TypeSafe Jev official | `jev-latest` | Choice | PASS | Exact candidate membership and returned choice validated; usage input 312, output 31 |
| TypeSafe Jev official | `jev-latest` | Score | PASS | Requested legend/index/range and typed decoding validated; usage input 302, output 18 |
| TypeSafe Jev official | `jev-latest` | Mixed | PASS | Noul, Choice and Score identities all matched the request; usage input 351, output 62 |
| Apple on-device | system model | Truncation and Calculator loop | PASS | Two opted-in tests passed: a one-token plan dispatched no tool, and a real two-turn plan caused exactly one Core-managed Calculator execution |
| Apple PCC | private cloud model | Calculator proposal | BLOCKED_PLATFORM | The opted-in test returned typed `ModelProviderError.unavailable`; no key or alternate cloud provider was substituted |
| AppleChatApp / OpenAI-compatible gateway | `gpt-5.6-luna` | macOS local read-only tool demo | PASS (execution), NOT RUN (visual) | Two sends and one local `lookup_account` loop completed through the existing Controller. A real 960x708 window was present, but UI automation lacked reliable window-content access |

## DeepSeek correctness finding

The service returned a complete, ordered response whose reasoning item included
output-only compatibility metadata. The old continuation encoder persisted that
metadata and later required it to appear in the request replay shape, causing a
typed `invalidResponse` at completed-continuation validation.

The remediation keeps provider item identity, order, visible reasoning text and
tool bindings, while omitting output-only `summary` and `encrypted_content` from
DeepSeek durable replay. The regression uses a controlled fixture and safe
stage/event diagnostics; no real reasoning content or wire payload was stored in
the repository. Focused DeepSeek tests passed after the change, and the final
budgeted service response completed with normalized usage.

## Evidence boundaries

- OpenAI and Anthropic results above are for explicitly configured gateways;
  they are not official-endpoint qualification.
- Jev and DeepSeek results used their configured official endpoints.
- Apple on-device passed on this machine; PCC availability did not.
- A cross-build is not iOS simulator or device UI acceptance.
- Request/token usage does not establish an exact monetary cost. No cost is
  reported because no trustworthy billing total was available.
- The DeepSeek cases marked `NOT RUN_BUDGET` remain required before broad live
  qualification can be called complete.

The independent read-only review found no remaining P0/P1/P2/P3 code or
documentation findings after remediation. Its evidence and the task-level
qualification adjudication are recorded in the
[independent review](2026-09-19-provider-live-qualification-independent-review.md).

## Reproduction entry points

Use the commands and configuration contract in
[Examples and live qualification](../guides/swift-agent-examples-and-live.md).
Normal package CI remains credential-free and must not inherit live switches.

## Final offline validation

The final code baseline `c17adeb86f5ea086e9ac9f2d454a41fbe7f85455`
passed the following local Swift 6.4 gates after the last fixture-isolation
change:

| Command | Result |
| --- | --- |
| `bash Scripts/ci-macos.sh` | PASS: root XCTest 127/127; root Swift Testing 451 discovered, 446 passed, 5 documented live skips; ExternalClient 7/7; ProviderQualification 22/22; AppleChatApp 21/21; macOS and iOS 16 cross-builds passed |
| `bash Scripts/ci-concurrency-seal.sh` | PASS: ToolResourceCoordinator 11/11; AgentCompletionCommit 4/4 |
| `bash Scripts/ci-apple-provider.sh` | PASS: 18 discovered, 15 passed, 3 opt-in live skips |
| `bash Scripts/ci-linux.sh` | PASS locally as a portability/target-isolation script; this macOS execution is not Ubuntu hosted evidence |

The test totals report discovered, passed and skipped counts separately. No live
switch was inherited by these ordinary gates.
