# SwiftAgent Tool Scheduling

last-verified: 2026-09-18

ToolScheduler executes prepared, schema-validated calls for the single AgentLoop.
Contiguous read-only parallel calls overlap. Sequential and exclusive calls are
batch barriers: preceding work settles before they start, and later groups wait.
One read failure stops subsequent groups; already-started independent reads settle
under their own deadlines so accepted results are not lost through sibling cancellation.
Run cancellation still cancels all pending work.

## Resources and Ownership

An Agent shares its scheduler across its Sessions. Share the same scheduler value
explicitly when multiple Agents operate on the same host resources:

```swift
import AgentCore
import AgentModels
import AgentTools

func makeSharedAgents(model: ModelID, provider: any ModelProvider,
                      tools: [any AgentTool]) throws -> (Agent, Agent) {
    let scheduler = ToolScheduler()
    let configuration = AgentConfiguration(scheduler: scheduler)
    return (
        try Agent(model: model, provider: provider, tools: tools, configuration: configuration),
        try Agent(model: model, provider: provider, tools: tools, configuration: configuration)
    )
}
```

AgentTool.resourceRequirements(for:) resolves identities from validated typed input.
The default is `[.global]`. Named resources use `.named(EvidenceReference(...))`;
an identity here does not grant evidence or authorization. Empty, duplicate or blank
resource declarations fail during preparation.

Read-only parallel/sequential calls take shared resource leases; exclusive calls
take exclusive leases. Global intersects every named resource. Older conflicting
waiters cannot be overtaken, while disjoint work may progress. Mutation reservations
are additionally serialized within the shared scheduler, even across disjoint keys.
Host authors must identify shared resources consistently and use a shared scheduler
for them. Separate scheduler instances are separate coordination domains.

## Deadlines and Completion

Each tool deadline begins at dispatch and includes waiting for resources,
authorization, execution and result validation. A timeout or cancellation stops the
caller waiting and signals the executor. The lease remains held until the actual
invocation exits, including uncooperative operations. A new conflicting invocation
cannot enter merely because the earlier Run settled.

Start events follow proposal order. Completion events reflect accepted-result
order; canonical tool messages always follow original proposal order. Failed batches
retain completed call/result pairs and drop opaque state tied to discarded proposals.

History checkpoint acceptance and completion events form one protected commit.
After a checkpoint succeeds, receipt and toolCompleted are published together before
runFinished, even if cancellation arrived between acceptance and event delivery.
Before acceptance, cancellation or checkpoint failure aborts that completion. The
finish path waits for these internal commits, not for native executors that ignore
cancellation. Checkpoint callbacks are internal lifecycle operations, not host work.

## Mutation Admission

Scheduling does not authorize effects. Mutation invocation remains closed until
durable intent and recovery prerequisites are available. The coordinator's mutation
tests prove reservation serialization; they do not claim production mutation execution.
Resource leases do not substitute for schema, evidence, authorization, real receipts,
journaling or reconciliation.
