# Host context integration (RC6 candidate)

SwiftAgent builds a request view; the Host owns summary generation, thresholds,
semantic correctness, cost, caches, project memory and presentation. This guide
prepares SDK integration. It does not claim any OtohaAI integration or live
Provider qualification.

## Call order

1. Wait for the preceding Run's `waitForDrain()` before replacing a Session or
   preparing sources that depend on its final committed history.
2. Load approved Host materials and, for older closed history, request
   `contextHistorySpan(start:count:)` or `contextToolExcerpt(callID:text:)`.
3. Capture those requirements and projector configuration in one
   `AgentModelBinding`. A transparent wrapper forwards
   `AgentContextSourceReferencing` and, when applicable,
   `AgentContextReadOnlyGroupReferencing`.
4. Run with that binding. Core supplies an immutable canonical source for each
   newly built model request. The first request reuses validated preflight;
   the projector is not called twice for that same request. The same projector
   object may return different views as tools or steering change the source.
5. Observe `wait()` for the logical outcome and `waitForDrain()` for physical
   release. A summary/projection failure does not authorize retrying an entire
   mutation Run.

`Examples/ExternalClient/Sources/ContextPipelineFixture/main.swift` uses only
public APIs. Its dynamic Host projector forwards fixed source requirements,
reuses a preprepared deterministic summary, and adds per-turn material from
the current input. A two-request Run invokes it twice; current input and tool
pairs remain intact. Cancellation during the second projection prevents a late
Provider dispatch and retains the already committed tool result. The fixture
also closes and reopens a real Journal. It is not a summary quality test.

## Budgets and cache identity

Configure `AgentContextPolicy.maxInputUTF8Bytes` and
`maxModelContextUTF8Bytes` plus an optional binding `tokenBudget`. The final
estimator input contains the actual declared tools and structured output;
reserves include output, reasoning and protocol allowances. Core verifies the
actual projected source revision, digest, epoch, tool pairing, continuation
origin and final budget. A Host cannot declare a view validated.

Startup budget failure does not admit the input. A later budget failure stops
the next model request while retaining committed tool results and execution
facts. Identity does not summarize automatically. Projector and estimator work
participate in deadline/cancellation and physical drain; an ignored cancellation
can delay drain but cannot dispatch a late request.

Cache prepared summaries by Session identity, exact source IDs/digest, Host
summary generator/prompt version and policy version. Revision and epoch are
live actor coordinates, not durable Journal versions. Source identity proves
correspondence, not semantic summary accuracy.

## Supported transformations

Composite materials, prepared summaries and prepared excerpts are bounded.
Ordinary summaries replace older closed text-only groups before the latest
user; excerpts replace eligible older successful read-only results. Composite
is not an automatic service for arbitrary outputs in the current tool batch.
Resolved read-only groups require Core-observed complete-group effect proof.
Do not infer proof from a summary, model text or a current same-name tool.
Reopening does not recreate process-local historical effect proof: preserve
the original view or accept the explicit restricted-conversion rejection.

A custom projector's general freedom is not proof that its transformation is
safe. Dynamic source-range selection and persistent historical effect
provenance remain separate design work; this candidate adds no such API.

## Provider and recovery boundaries

Projection changes only the request view. Canonical messages, mutation
identity, receipts, pending records, reconciliation and tools already executed
remain unchanged. Opaque continuation and signed thinking may impose stricter
Provider-specific restrictions than structural pairing and source checks;
consult the Provider support matrix before changing system/tools/old messages.
An explicit semantic handoff is lossy and does not fabricate native state.

After a stale persistent-history error, wait for physical drain and create a
new Session with the same ID and Journal handle. After mutation uncertainty,
use Host-verified reconciliation first; do not replay the mutation or alter the
old Run's logical terminal. No whole shared Journal shutdown is required.
