# Claude Fable 5.1 SAI-055 Independent Review

last-verified: 2026-09-19

## Review record

- Model: Claude Fable 5.1 (`claude-fable-5-1`), as reported by the reviewer runtime.
- Reviewed repository: `OtohaPlayer/SwiftAgent`.
- Baseline: `d139e5d74bdb746a28b8fdf3a44c593502b44fc6`.
- Reviewed commit: `a7f76c1096e1bbb310c2d6702d6cfec850187db9`.
- Invocation: Herdr agent prompt to the dedicated Claude pane `w1A:p5` from the
  Tingting workspace. The exact prompt is preserved in
  [the prompt record](prompts/2026-09-19-claude-fable-5-1-sai-055-review.md).
- Method: detached export of the reviewed commit, baseline diff and surrounding
  source review, independent TypeSafe OpenAPI verification, focused builds and
  tests, fixture example, ExternalClient, and a reviewer-only crash reproducer.

The reviewer reported `P0: 0`, `P1: 1`, `P2: 0`, `P3: 3` and a `BLOCKING`
verdict on the single P1. It found the Decision/AgentCore security boundary
intact and considered the additive public API suitable for the next RC after
the blocker was fixed.

## Findings and disposition

### P1-1: oversized numeric Retry-After can trap

**Reviewer finding:** `retry-after-ms: 1e30`, `Retry-After: 1e300`, and a large
hexadecimal floating-point value reached `Duration.milliseconds(Double)` or
`Duration.seconds(Double)`. Swift trapped during integer conversion instead of
returning the classified HTTP error.

**Disposition: Accepted.** The failure was reproduced locally by the permanent
test before the production fix: the test process exited with signal 5 at
`Swift/LegacyInt128.swift` with `Fatal error: Overflow in multiplication`.
The adapter now converts whole and fractional components only after checked
`Int64` conversion. Unrepresentable metadata becomes `nil`; the original typed
HTTP failure remains intact and no retry is introduced. The regression covers
all three reviewer inputs.

### P3-1: public response values do not self-validate

**Reviewer finding:** third-party providers or decoded persisted values can
construct probabilities, confidence values, or membership combinations that a
Jev response decoder would reject.

**Disposition: Partially accepted, non-blocking.** The observation is correct,
but `DecisionResponse` is provider output and deliberately remains a simple,
vendor-neutral value. Membership validation needs the corresponding
`DecisionRequest`, so forcing it into each stored-value initializer would not
establish the complete invariant. Decision output remains untrusted advice and
cannot cross the execution boundary. An additive future
`validate(against:)` helper is a reasonable post-SAI-055 API candidate; it is
not required to close the Jev adapter, which validates before publishing.

### P3-2: URLSession redirect refusal lacks Linux runtime evidence

**Reviewer finding:** fixture transports do not directly prove
FoundationNetworking's redirect delegate behavior on Linux.

**Disposition: Needs evidence, non-blocking.** The production transport refuses
redirects and the module builds and passes its adapter tests on Ubuntu 24.04,
but the exact live loopback redirect behavior is not claimed by SAI-055. A
deterministic Linux loopback transport test remains follow-up evidence; this
does not weaken the current no-redirect implementation or the fixture protocol
contract.

### P3-3: one ephemeral URLSession per decision

**Reviewer finding:** creating and invalidating a session per call prevents
connection and TLS reuse.

**Disposition: Accepted as a performance trade-off, non-blocking.** The first
adapter favors per-call credential, cookie, cache, cancellation, and redirect
isolation. A shared transport can be evaluated later without changing the
public decision contract. No performance or correctness claim requires it in
SAI-055.

## Verified non-findings

- Official OpenAPI SHA and Jev request/response mapping matched the design.
- No invented probability-sum tolerance or synthetic no-result answer exists.
- `AgentCore` imports neither decision product; Decision has no executor,
  Evidence, Receipt, mutation-admission, or journal-settlement authority.
- API keys and payloads are absent from descriptions and classified errors.
- Deadline/cancellation settlement, Swift 6 Sendable boundaries, architecture
  guards, fixture example, and ExternalClient were accepted.

## Follow-up review

Pending focused re-review of the P1 fix commit.
