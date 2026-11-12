# SwiftAgent Tool Scheduling

last-verified: 2026-11-12

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
and every mutation take exclusive leases. An exclusive lease conflicts with any
lease whose resources overlap; global intersects every named resource. Older
conflicting waiters cannot be overtaken, while disjoint work may progress. Two
mutations with disjoint named resources run at once, also across Sessions on
one scheduler (before, any two mutations waited for each other).

A mutation tool can also tell, per input, that a call only observes:
`AgentTool.readOnlyPolicy(for:)` returns the read-only policy that call runs
under (a shell tool reading a file, say). Such a call takes a shared lease on the
same resources, joins neighbouring parallel reads when its execution is
`.parallel`, and is settled as a read: no mutation intent, no reconciliation.
The other calls of the tool stay exclusive mutations. The answer must follow from
the input alone; a policy that is not read-only fails the call's preparation.
`ToolContext.effect` tells the tool and its wrappers which effect a call runs
under, so a wrapper reports a refusal of a read as a model-visible error and a
refusal of a change as a confirmed no-effect.

The names are the whole contract: the scheduler cannot see what a tool really
touches. A mutation must name every resource another Session's call could
observe or change at the same time, or keep the default `[.global]`. Prefer one
coarse name (a project, an account) over per-item names that may alias (case or
Unicode spellings of one path, two routes to one record). Receipt targets and
Evidence references may be finer than the lease names; they are checked
separately. Host authors must identify shared resources consistently and use a
shared scheduler for them. Separate scheduler instances are separate
coordination domains.

A Host's own operation on such resources, outside any Run, takes the same lease
with `ToolScheduler.withLease(on:effect:until:_:)`: a mutation waits for and keeps
out conflicting calls, a read shares with reads. Never take it from inside a call's
executor for resources that call already holds on the same scheduler.

## Deadlines and Completion

A call's time has three parts, each bounded separately, and all by the Run's
deadline:

- Authorization before the lease (the default `beforeResourceLease` timing, or
  audited authorization) waits up to `ToolScheduler(authorizationWaitLimit:)`.
  Past it the model gets a `not_answered` result and the call never runs.
- The resource lease wait is bounded by `leaseWaitLimit`. Past it the model gets
  a `busy` result and the call never runs.
- `ToolPolicy.timeout` starts once the lease is held, just before the invocation,
  and covers admission checks, the mutation intent, the executor and result
  validation. Under `whileHoldingResourceLease` the tool's authorization runs
  inside that invocation and counts against this timeout.

Both limits default to nil: only the Run's deadline bounds those waits. Under
audited authorization, a wait past either limit fails the call with
`toolTimedOut` instead. A timeout or cancellation stops the caller waiting and
signals the executor. The lease remains held until the actual
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
