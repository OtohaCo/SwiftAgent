# SAI-069 Usage Accounting Independent Review

last-verified: 2026-09-20

## Review identity

- Invocation: Herdr agent pane `w1A:p5`, read-only review.
- Reviewer model reported by the agent: Claude Opus 5 (1M context), model ID
  `claude-opus-5[1m]`.
- Delivery baseline: `8d06a273f990b72bb9e1f64af73c84c7dc6bf765`.
- Initial review candidate: `7293b7aea211d4d080c3af70c83a2aec4ea953bc`.
- Final focused review candidate: `a3b6d86b1f3b4c4675b00e79fedc09cc3c6d2abb`.
- Scope: usage snapshot merging, cross-response completeness, deduplication,
  checked arithmetic, one-consumer event ownership, cancellation/drain, public
  API boundaries, and AppleChat display integration.

## Initial findings and disposition

| Severity | Finding | Disposition | Fix |
| --- | --- | --- | --- |
| P2 | AppleChat kept cancelled or failed provisional usage labelled as an active response. | Accepted | `ef16693e823408390996afe7a3ee8b2ac884f2e6` distinguishes active, draining, and historical partial reports. |
| P2 | Qualification cancellation paths could rethrow a non-`CancellationError` before physical drain and observer join. | Accepted | `ef16693e823408390996afe7a3ee8b2ac884f2e6` centralizes best-effort drain and joins the single event observer before returning or rethrowing. |
| P3 | Overflow in a multi-record subtotal could lose its incomplete state after a later successful addition. | Accepted | `d7414df5f8db74fe58c6e9108b7774ebd7ac5661` makes overflow sticky and adds a direct regression. |
| P3 | Model identity stability within one response needed explicit documentation. | Accepted | The design and usage guides require every observation to use the started response's `ResponseInfo.model`. |
| P3 | Long-lived in-memory windows can require retention or indexing policy. | Accepted as follow-up | Tracked separately in Tingting as SAI-070; it is not a correctness blocker for the explicit in-memory window delivered here. |
| P3 | A sparse cache-subset snapshot should be accepted when a later total is lower. | Rejected | Under the cumulative same-response contract, a cached-input subset larger than the reported total is invalid. Atomic rejection preserves the last valid state. |

## Focused follow-ups

The first remediation review found that `turnStarted` numbers restart at one for
each Run. Reusing that number as `DisplayAssistantTurn.id` therefore produced
duplicate SwiftUI row identities across Runs and could label an older
provisional response as current. It also noted that one internal overflow test
had widened the whole usage suite to `@testable import`.

`a3b6d86b1f3b4c4675b00e79fedc09cc3c6d2abb` closes both findings:

- `ConversationProjection` assigns conversation-scoped monotonic assistant
  display identities and publishes the current identity in its snapshot.
- The view consumes that explicit identity instead of deriving it from the last
  row or the Run-local turn number.
- The internal arithmetic regression lives in its own `@testable` file, while
  `UsageLedgerTests` again exercise only the public `AgentUsage` API.

The final reviewer probe observed assistant IDs `[1, 2]`, unique
`ConversationItem.id` values, exactly one current assistant row, and the older
provisional response remaining `partial` while the next Run was active.

## Final result

Final focused review: **CLEAN**.

- P0: 0
- P1: 0
- P2: 0
- P3: 0

The reviewer found no new SDK public API, concurrency, physical drain, Session
lease, tool settlement, or AgentCore behavior regression. Remaining notes are
non-blocking: the AppleChat aggregate Session label intentionally has coarser
provisional granularity, and UI composition remains subject to manual visual
acceptance rather than a new UI automation framework.
