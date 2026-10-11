# Anthropic request boundaries (RC6 candidate)

The adapter checks the fully serialized JSON HTTP body in both `validate(request:)` and `stream(request:)`, before transport. The bytes checked by the stream are the exact `httpBody` sent. Its ceiling is **32,000,000 bytes**, inclusive. Anthropic's [API errors documentation](https://platform.claude.com/docs/en/api/errors) states **32 MB** for Messages requests without specifying the byte conversion; RC6 conservatively interprets MB as decimal. This is an SDK acceptance ceiling, not evidence of a service accepting every body of that size. Base64, escaping, messages, system instructions, tool schemas and structured output all count. Raw-image selection limits remain separate: 24 MiB of raw images cannot be promised to fit this ceiling, and default 20 MiB plus text can exceed it. Oversize bodies produce local `ModelProviderError.invalidRequest`; no transport call or automatic retry occurs.

## Preserved thinking

RC6 uses a conservative local unchanged-prefix policy, without adding beta fields or asking the service to drop thinking. For responses containing native `thinking` or `redacted_thinking`, the opaque Anthropic continuation stores a SHA-256 witness of the wire `system`, ordinary top-level `tools`, and preceding `messages` from the request that produced it. Every replay validates that witness against the newly encoded prefix before transport. This is a local correspondence check, **not cryptographic validation of an Anthropic signature**. Signed blocks are retained unchanged in canonical history.

The [preserved thinking documentation](https://platform.claude.com/docs/en/build-with-claude/preserved-thinking) currently lists Fable 5.1, Opus 5.5, Sonnet 5.5 and Haiku 5.5 prefix checks, enforced by default for accounts created on or after August 31, 2026, and on requests explicitly selecting the beta mismatch behavior. RC6 does not infer account age from a key, generation or model name. It applies the local policy to all replayed signed thinking to avoid silently relying on an account exemption. This does not mean every Anthropic configuration enforces the service check.

| Request path | Local RC6 result |
| --- | --- |
| Fixed tools/system, append-only native continuation with RC6 witness | Accepted |
| SDK deferred declaration expands ordinary top-level tools with existing signed thinking | Rejected before transport |
| A subsequent Run resets tools while replaying thinking produced under expanded tools | Rejected before transport |
| Summary/excerpt changes a message before retained signed thinking | Rejected before transport |
| History has no native signed/redacted thinking | Existing supported paths remain accepted |
| Legacy signed continuation lacking a local witness | Rejected before transport; original conversation remains intact |

A Host can retain an append-only request view and fixed declarations, or explicitly choose a request view without native thinking under its own projection contract. Do not silently mutate stored continuations or replay a Run after refusal: tools already executed remain executed. SDK deferred tools are not provider-native `defer_loading`. RC6 does not implement provider compaction, dynamic tool blocks, or beta `drop_block` response transformation handling. Cross-model and cross-account signature acceptance remains the provider's responsibility; matching local witnesses do not establish live qualification.

Tests use Swift encoding and HTTP SSE fixtures. Fixture signatures only exercise opaque replay and local policy; they are not valid service signatures. No paid live requests were added, and no newly supported real-model qualification is claimed.
