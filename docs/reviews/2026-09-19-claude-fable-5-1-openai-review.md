# Claude Fable 5.1 OpenAI Responses Diff Review

> last-verified: 2026-09-19

## Metadata

- Repository: `OtohaPlayer/SwiftAgent`
- Base SHA: `a66c19f45e4c394002ada1c88bcf5ce2f1b7d712`
- Reviewed change: uncommitted SAI-054 implementation
- Model: Claude Fable 5.1
- Invocation: existing Herdr workspace Panel 2
- Mode: read-only diff review with reviewer-owned reproductions in a copy

## Initial Findings

The reviewer confirmed 11 adapter tests and reproduced three additional cases.
It found two P1 blockers, two P2 issues, and six P3/API risks.

| Finding | Initial severity | Codex disposition | Result |
| --- | --- | --- | --- |
| Truncated function call became `invalidResponse` | P1 | Accepted | Incomplete call is retained with `.maxOutputTokens`; executor remains at zero |
| Alias request rejected a resolved snapshot with no configuration path | P1 | Accepted | Exact by default; explicit `resolvedModelIDsByAlias` accepts only the declared snapshot |
| Stream `error` and `response.failed` always became `.unavailable` | P2 | Accepted | Stable codes map to typed sanitized kinds; unknown codes fail as `.invalidResponse` |
| Stateless reasoning items were dropped between tool turns | P2 | Accepted | Encrypted reasoning and function item identity round-trip through opaque continuation |
| Closed reasoning enums would require repeated source-breaking expansion | P3 | Accepted | Replaced by extensible raw-string value types with documented constants |
| Unknown output item type lacked a useful capability classification | P3 | Accepted | Fails as `.unsupportedCapability` without becoming a host tool call |
| Recoverable error envelope was undocumented | P3 | Accepted | Guide and encoder regression now freeze the JSON envelope |
| Fixture asserted nonexistent cache-write usage | P3 | Accepted | Removed; OpenAI cache reads remain normalized |
| Final response output was not checked against streamed calls | P3 | Accepted | Final reasoning/function items must exactly match streamed terminal items |
| Assistant replay used the easy string input instead of `output_text` parts | P3 | Accepted | Assistant items use explicit `output_text` content parts |

## Security Result

No Core change was required. Provider-hosted tools remain unsupported and are
rejected before any `ModelEvent.toolCallStarted`. All host function proposals
still pass AgentCore schema validation, Evidence, authorization, durable intent,
executor, Receipt validation, and settlement. OpenAI response IDs and encrypted
reasoning remain provider-owned opaque state, never conversation authority or
trusted runtime state.

## Required Remediation Verification

Named coverage lives in `OpenAIResponsesProviderTests` and
`OpenAIResponsesFailureTests`, including truncation without execution, explicit
model identity, stream error taxonomy, continuation replay, final-output
divergence, cancellation, structured output, usage, and hosted-tool rejection.
A second Panel 2 pass is required after the completed diff and validation.

## Remediation Reviews

Panel 2 reviewed the remediated implementation twice more. The second pass
confirmed the initial P1/P2 findings were fixed and identified one API naming
hazard: a static `.none` reasoning value resolves as `Optional.none` at an
optional call site. The public constant is therefore `.disabled`, while its
OpenAI wire value remains `"none"`.

The third pass confirmed semantic terminal comparison, missing-encrypted-state
degradation, native continuation order, diagnostic sanitization, canonical tool
identity, and the provider-state boundary. It then reproduced one additional P2:
an OpenAI refusal content part was rejected because terminal message validation
accepted only `output_text`. The decoder now validates both documented message
part forms, the named regression terminates as `.refused`, and unknown part
types still fail closed.

Two reviewer P3 observations remain non-blocking by design:

- `reasoning.encrypted_content` is requested for stateless official OpenAI
  compatibility even when no explicit reasoning effort is configured.
- final output must have the same completed item indexes as the stream. Unknown
  or unstreamed terminal items remain a protocol failure rather than being
  silently accepted.

Final disposition: no open P0, P1, or P2 finding in SAI-054. AgentCore was not
changed, provider-hosted tools remain unsupported, and provider continuation
cannot replace canonical conversation, Evidence, authorization, Receipt, or
journal state.
