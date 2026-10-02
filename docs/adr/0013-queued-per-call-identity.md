# ADR 0013: Explicit queued mutation identity

Status: Accepted (unreleased). Scope: Issue #74.

A future queued input can select existing per-call Run/call identity or the
existing logical operation identity. Old initializers/records retain logical
operation semantics. Input and public record operationID becomes optional;
identity is explicit, without synthetic IDs or tool-specific mixed policies.

Opt-in store creation uses schema 8 and all schema-7 capabilities. Existing
stores are not migrated. Unsupported enqueue fails before admission. A new
field alone is insufficient: the actual schema-7 reader uses permissive DTO
decoding and maintenance could discard it. Its unmodified format check rejects
schema 8, including an empty store. The reader matrix executes that binary.

This changes identity choice only. It does not replay, settle, reauthorize or
unblock an interrupted mutation, and creates no task or scheduling abstraction.
