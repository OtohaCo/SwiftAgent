# SwiftAgent Security Model

last-verified: 2026-09-18

This document states what the SDK guarantees and what remains the host's job.
It is part of the 1.0 freeze.

## LLM output is untrusted

A model response is a proposal. Text, tool names, arguments, and structured
output are not authorization, not Evidence, and not a Receipt. The runtime
must not treat model content as proof that a resource exists, that a mutation
happened, or that the host should skip policy.

## A tool call is a proposal

Every complete tool call still passes:

1. Schema validation for input
2. Evidence requirements when the tool policy requires them
3. Authorization when the tool policy requires it
4. Resource identity for the scheduler
5. Receipt expectation for mutation and receipt-backed tools

Failing any step fails the call. Completeness on the wire only means the
transport finished the call payload.

## Mutation is not success until receipt

Executor return is not settlement. A mutation is successful only after
`ToolReceiptValidator` accepts a receipt that matches the durable operation
identity and targets, and the journal records settlement. Model text that
claims an effect does not create a receipt.

## Crash does not replay mutation

Restart recovery moves unsettled intents to `needsReconciliation`. The SDK
does not replay the host executor and does not infer success from the crash
tail. The host reconciles with a trusted receipt or aborts.

## Provider fallback cannot replay an uncertain mutation

Once a mutation boundary is crossed, switching provider candidates for that
run is blocked. A later model must not retry an effect whose outcome is
unknown.

## Evidence does not equal authorization

Evidence is a trusted observation recorded by a tool or host. It answers
"this resource was seen in this session or run." Authorization is a separate
allow/deny decision. A valid Evidence record does not grant mutation rights.

## Receipt does not equal arbitrary host assertion

A receipt is bound to the admitted operation, idempotency key, and declared
targets. Hosts cannot mark an intent settled with unrelated JSON. Reconciliation
must satisfy the original expectation.

## Host executors remain the trust boundary

The SDK can:

- Refuse to open a mutation Session without durable journal storage
- Admit a mutation intent before the executor runs
- Validate receipts and refuse to settle on mismatch
- Keep scheduler isolation for shared resources
- Keep provider adapters from executing host tools

The SDK cannot:

- Make an untrusted host executor honest
- Prove an external system changed without a receipt from that system
- Prevent a host from implementing `AgentTool.execute` incorrectly
- Replace operating-system sandboxing, secrets handling, or user consent

Otoha, MusicKit, file systems, and other product executors stay outside Core.
WorkspaceAgent is a Reference Host that demonstrates the contract; it is not a
security boundary for other apps.
