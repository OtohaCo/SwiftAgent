# SwiftAgent Security Model

last-verified: 2026-11-10

This document states what the SDK guarantees and what remains the host's job.
It describes the code on this development line, including the unreleased
changes listed in the [changelog](../CHANGELOG.md) and ADRs 0011–0018. A
[host obligations checklist](#host-obligations-checklist) closes the document.

## Model catalog and routing are not trust boundaries

`AgentCatalog` describes a provider deployment and records whether a capability
is supported, unsupported, or unknown. A discovered model is not automatically
an executable model, and a stale or partial catalog does not prove that an
upstream request will be authorized. The Host must bind a concrete provider,
deployment, model, and parameter profile before starting a Run.

`AgentModelBinding` is immutable for one Run. Changing a Host selection affects
a later Run; it cannot mutate an active loop or change the provider used while
an earlier Run is draining. `DecisionProvider` and Jev may select only from a
finite Host-approved candidate set. They cannot create an endpoint, credential,
provider option, Evidence record, authorization result, Receipt, or Journal
settlement.

Context projection is request input, not execution truth. A projector may
remove provider-private continuation or summarize an explicitly resolved
read-only interaction, but formal Session messages, tool-call/result
pairing, Evidence, mutation state, and indexed Journal recovery remain separate.
Projection output cannot mint Evidence or upgrade the authority of a message.

Native context operations ([ADR 0015](adr/0015-native-context.md)) follow the
same rule. Provider compaction produces a separate effective checkpoint; the
canonical messages and tool and mutation facts are never compressed or
replaced. Opaque provider state from a native transformation is scoped to the
adapter or route owner, model, deployment and source lineage that produced it.

The durable follow-up queue stores an input and non-authorizing configuration
reference, not a provider, credential, executor, capability binding or prior
authorization. Only explicit Host dispatch resolves a current Session-bound
capability and enters the normal evidence/authorization/durable-intent path.
An admitted input cannot return to queued after a crash. A Host's explicit
inspection may unblock *later* inputs, but cannot settle or silently abort
an uncertain mutation. `inputID` deduplicates reception within one actual
store and Session; `operationID` remains the distinct, stable identity for
external mutation retries. A queued input selects either that logical
operation identity or a per-call identity explicitly
([ADR 0013](adr/0013-queued-per-call-identity.md)); the choice changes identity
only and never replays, settles or reauthorizes an interrupted mutation.

Durable Run records ([ADR 0014](adr/0014-durable-run-association.md)) bind a
Host correlation key to the formal input and operation ID. The Host's payload
digest declares configuration identity; it neither freezes Host code nor
restores runtime handles or permissions. Terminals store only closed, bounded
enums: no provider text, error descriptions or credentials.

## LLM output is untrusted

A model response is a proposal. Text, tool names, arguments, and structured
output are not authorization, not Evidence, and not a Receipt. The runtime
must not treat model content as proof that a resource exists, that a mutation
happened, or that the host should skip policy.

## Untrusted content in the conversation

The SDK does not detect or remove instructions hidden in data. Every message a
model reads can influence its next proposal, so the controls that matter are
the ones after the proposal: schema validation, Evidence, authorization,
resource scope and receipts. What the SDK does guarantee is where each kind of
content sits in the conversation, because models give different roles
different weight.

- **Tool output** (from model calls) is a tool result paired with its call. Its
  content is whatever the executor returned, including text and images taken
  from files, web pages or other people's systems. A recoverable error's
  `code`, `message` and `details` are shown as the tool author wrote them; fixed
  SDK refusal texts never repeat the tool name, arguments or a thrown error.
- **Host call results** ([ADR 0011](adr/0011-host-initiated-tool-invocation.md),
  [ADR 0018](adr/0018-host-call-results-as-tool-results.md)) are committed as a
  call in the Host's `host-call-` namespace followed by a tool result, after a
  user-side message holding the Host's request (its note and arguments). A
  replayed or reconciled result says so in a leading fixed text part. A model
  proposal that uses the Host prefix ends its Run before preparation, so a model
  cannot make a call in the Host's name. A Host call that fails without a result
  is reported on the user side in fixed SDK words only; no tool output reaches
  the user side. Conversations committed before ADR 0018 keep their earlier
  user-side result notices until the Host starts a new conversation.
- **Context materials** (`AgentContextMaterial`, ADR 0005) are still projected
  as user-side text, labelled as Host context and "source data, not
  instructions". The label is wording, not a role boundary. They stay on the
  user side because as synthetic tool pairs they would place an assistant turn
  before the first user message, and in a request without tool definitions
  some wire formats reject tool blocks. They are request-time data the Host
  selects and are not committed to history.
- **Host notes and Run inputs** are user-side messages. The Host-call header
  wording is not authenticated: other user-side text could imitate it.

A Host that places content from someone else (a third-party panel, a web page,
a plugin) in a context material, a Host note, a Run input or steering gives it
the user's role. Return such content from a tool instead.

## Decision output is not authorization

`DecisionProvider` returns typed Noul, Choice, and Score advice. Confidence or
probability, including `1.0`, does not create Evidence or permission. The
decision API has no tool executor, Receipt, journal, or mutation-admission
surface. A Host that turns a decision into a later tool proposal still enters
the normal AgentCore path: schema validation, Evidence, authorization, durable
mutation intent, executor, Receipt validation, and durable settlement.

Decision providers are also separate from `ModelProvider`. They do not own a
conversation loop or become a second orchestration authority.

## A tool call is a proposal

A Session may bind an immutable tool registry and exact resource set to one
Run. Its process-local scope owner checks generation at final execution
admission, after resource waiting, Evidence, Host authorization and durable
mutation intent. Revoking the whole scope first prevents executor admission;
admission first creates in-flight work that retains cancellation and physical
drain ownership. Revocation never proves that an external effect was undone,
does not authorize an unrelated result replay and cannot erase a pending
mutation. Scope/version/Run IDs do not enter the logical idempotency key.

The SDK does not authenticate arbitrary Host backend code or enforce OS
isolation. The Host must use stable shared scheduler/resource identities,
approve the underlying account/workspace/backend version and avoid mutable
backend swaps inside a captured tool value. Neither model text, Context Skill
data nor a serializable scope diagnostic can mint a new execution binding.

Authorization that may wait for a person or a network service holds no
scheduler resource lease: audited authorization and, by default
(`ToolAuthorizationTiming.beforeResourceLease`), a tool's own required
`authorize` run before the call waits for its lease. Evidence and scope are
checked again under the lease, before mutation admission and the executor. The
decision may therefore be older than the state the executor sees; a Host tool
whose decision depends on mutable state must recheck it in the executor
(versioned reads or conditional writes), or its scheduler can use
`.whileHoldingResourceLease`.

Every complete tool call still passes:

1. Schema validation for input
2. Evidence requirements when the tool policy requires them
3. Authorization when the tool policy requires it
4. Resource identity for the scheduler
5. Receipt expectation for mutation and receipt-backed tools

Failing any step means the executor does not run, or, for a receipt failure,
that the mutation does not settle. Whether the Run continues is described in
the next two sections. Completeness on the wire only means the transport
finished the call payload.

## Refusals before admission reach the model

[ADR 0016](adr/0016-pre-admission-tool-outcomes.md) makes these outcomes error
tool results (`isError: true`) that are committed like any result, after which
the Run continues:

| Case | `code` |
|---|---|
| Tool name not offered or not yet declared in the Run | `unknown_tool` |
| The tool's `authorize` returned `.denied` | `not_allowed` |
| The tool's `authorize` threw `RecoverableToolError` | the error's own `code` |
| The tool's `authorize` threw any other error | `authorization_failed` |
| Authorization outlived `ToolScheduler.authorizationWaitLimit` | `not_answered` |
| The lease wait outlived `ToolScheduler.leaseWaitLimit` | `busy` |

This holds for mutations too, because every case is decided before executor
entry and before a mutation intent is written; a refused call has no effect to
reconcile. Repeated refusals are bounded by `maxToolCalls` and
`maxModelTurns`. A Host that wants a refusal to stop the task cancels the Run.
A Host-initiated call that its tool refuses returns the same result to the
Host; naming a tool outside the supplied binding still throws.

These still end the Run: cancellation, the Run deadline, the tool timeout,
revoked capability scope, Evidence failures (with the bounded replanning of
ADR 0008), integrity failures, the audited authorization decision of ADR 0009,
and every failure after a mutation intent is written (executor error, timeout,
invalid receipt or output), which also marks the mutation as needing
reconciliation.

## Model-visible tool failure is not a runtime failure

A read-only tool may opt into `ToolPolicy.RecoverableErrors.modelVisible` and
throw an explicit `RecoverableToolError` from its executor. Only that
three-part combination is converted into a structured model-facing tool result:

```json
{"code":"not_found","message":"No matching resource was found."}
```

The result has `isError == true`, uses the current tool call ID, enters the
canonical conversation, and consumes the normal tool-call and model-turn
budgets. The author controls every model-visible field; Core never stringifies
an arbitrary underlying error. `ToolPolicy` refuses `.modelVisible` for
mutations: an executor failure after the intent is written may have changed
something.

The same tool's output that breaks its declared output schema, or cannot be
encoded as JSON, also becomes a model-visible result with code
`invalid_output`: Core writes fixed diagnostics with the registered tool name,
schema-declared path components and array indices. An unrecognized output key
and its remaining path become `/<unrecognized>`; rejected values and dynamic
keys are never echoed. The invalid output, images, Evidence, declared tools and
receipts are discarded. The model may choose another approach within the
existing budgets. Every other tool's invalid output still ends the Run. A
declared read-only effect remains the Host's responsibility, not proof that an
arbitrary executor had no side effects.

Input schema errors use the preparation-time `invalid_arguments` tool result
before executor invocation; they do not end the Run. Other executor errors,
Evidence, receipts, journal persistence, reconciliation, cancellation and
deadlines end the Run. A recoverable error publishes no Evidence and carries no
Receipt, so text in its payload cannot establish a trusted observation or claim
a side effect. `.failClosed` keeps terminal failure for executor errors.

## Mutation is not success until receipt

Executor return is not settlement. A mutation is successful only after
`ToolReceiptValidator` accepts a receipt that matches the durable operation
identity and targets, and the journal records settlement. Model text that
claims an effect does not create a receipt.

## Crash does not replay mutation

Restart recovery moves unsettled intents to `needsReconciliation`. The SDK
does not replay the host executor and does not infer success from the crash
tail. The host reconciles with a trusted receipt and output, or explicitly aborts
only after confirming there was no external effect.

This holds for a process crash. Whether an acknowledged intent or settlement
survives power loss or an operating-system crash depends on the storage flush,
described under [Data at rest](#data-at-rest).

## Durable deduplication is journal-wide

Mutation deduplication is scoped to one open durable store and its persisted
operation domain, not to a Session or Run. Another directory with the same
domain label has a separate ledger. `operationID` names the logical operation and must stay stable
across retry attempts. For a non-nil `operationID`, the durable identity combines:

- The stable `operationID`
- The tool name
- The canonical semantic JSON arguments

Tool call ID, Session ID, and Run ID are excluded. Equivalent JSON object key
ordering, numeric spellings such as `1` and `1.0`, and equivalent JSON string
escapes therefore resolve to the same identity. Changing the tool or semantic
arguments creates a different identity and cannot reuse the prior settlement. A
nil or blank `operationID` falls back to a per-call identity and provides no
cross-run deduplication. A fixed `operationID` therefore also makes two
intentionally identical calls in one Run the same operation: the second replays
the first's settlement. Host-initiated mutations use the key
`host:<operationID>/<tool>/<arguments>`; Runs and queued inputs cannot name
`host:` operations.

Admission fails closed according to the latest durable lifecycle:

- `intent` throws `AgentJournalError.mutationPending`; a second intent is not
  created and the executor does not run.
- `needsReconciliation` throws
  `AgentJournalError.mutationRequiresReconciliation`; the executor does not run.
- `settled` validates and reuses the original receipt without invoking the
  executor. Executor settlements durably preserve the canonical JSON tool
  output, so replay remains valid against the declared output schema.
  Transcript and run receipt records use the current tool call ID, not the
  original attempt's call ID.
- `aborted` permits a new lifecycle for the same logical identity. Abort means
  the trusted Host explicitly confirmed that the prior attempt produced no
  external side effect; cancellation or uncertainty alone is not an abort.

Authorization and Evidence checks currently run before durable replay admission,
so a settled receipt does not bypass current policy. Reconciliation requires a canonical replay output alongside the receipt.
Terminal identities are retained without a TTL while the operation domain
exists. The new segmented schema does not read older framed Journal versions.

## Provider fallback cannot replay an uncertain mutation

Once a mutation boundary is crossed, switching provider candidates for that
run is blocked. A later model must not retry an effect whose outcome is
unknown.

## Provider fallback cannot hand one candidate's state to another

Route candidates are separate service instances. Opaque continuation state
(for example encrypted reasoning) is recorded with the candidate that produced
it and is sent back only to that candidate. A request carrying it is served by
its owner or refused with `fallbackBlocked`; so is state whose candidate the
Route cannot identify. Declare `ModelProviderRoute.Candidate` IDs so this holds
across restarts and candidate reordering.

## Evidence does not equal authorization

Evidence is a trusted observation recorded by a tool or host. It answers
"this resource was seen in this session or run." Authorization is a separate
allow/deny decision. A valid Evidence record does not grant mutation rights.

## Receipt does not equal arbitrary host assertion

A receipt is bound to the admitted operation, idempotency key, and declared
targets. Hosts cannot settle an intent with a receipt for a different
operation or target: reconciliation validates the receipt against the original
expectation.

The output a Host supplies to `reconcileMutation` is not checked by the SDK: it
is not validated against the tool's output schema and is not cut to the tool's
result size limit. It is committed as the settled output and returned by every
later replay of that operation. The Host must supply output that the tool
itself could have returned.

## Scheduler sharing and resource leases are safety preconditions

Isolation is per `ToolScheduler` instance, not per Session. Two Sessions that
can change the same workspace, account or other object must use the same
scheduler; Sessions on different schedulers never wait for each other.

Since [ADR 0017](adr/0017-resource-scoped-mutation-leases.md), a mutation takes
an exclusive lease on its declared resources only. Two leases conflict when at
least one is exclusive and their resources overlap; `.global` overlaps every
resource. A tool that declares nothing gets `[.global]` and waits for every
other call. Resource names are compared byte-exactly: the SDK does not fold
case or Unicode spelling, so names that alias the same object (for example on a
case-insensitive volume) are different leases. The declared resources are the
whole cross-Session contract for mutations. A tool must name everything it
may touch, or a coarser name that covers it, or `.global`.

An executor that outlives its timeout or cancellation keeps its lease until it
physically returns, and the Session's next Run or Host call waits for that
drain (bounded by its own deadline). The SDK cannot stop an executor that
ignores cancellation.

## Denial-of-service limits

Bounded by the SDK:

- **One tool result.** `AgentTool.maximumResultBytes` (default 1 MiB of encoded
  JSON output, minimum 4 KiB) applies before a result is committed, for model
  and Host calls. A larger output is replaced by a `truncated` object that fits
  the limit and keeps the start of the output. Receipts, Evidence and images
  are kept. The limit is per result: the Run's model context byte limit still
  applies to the whole history, and a history over it fails the Run with
  `historyTooLarge`. Reconciliation output is not cut (see above).
- **One server-sent event.** HTTP model providers accept
  `maximumSSEEventBytes` (default 16 MiB); a larger event fails with a fixed
  `eventTooLarge` diagnostic. HTTP error bodies are read up to 64 KiB.
- **Images.** At most 8 images per tool result, 3.75 MiB and 8,000 pixels a
  side per image ([ADR 0012](adr/0012-image-content.md)); per-request totals
  follow the Run's `AgentImageInputPolicy`.
- **Waits.** `ToolPolicy.timeout` covers execution once the lease is held.
  `ToolScheduler(authorizationWaitLimit:leaseWaitLimit:)` bound the wait for an
  answer and for a lease; both default to nil, leaving only the Run deadline.
- **Turns and calls.** `maxModelTurns`, `maxToolCalls` and the Run deadline.

Not bounded by the SDK:

- **Ordinary Run events.** The event stream of a Run started with `run` buffers
  without limit; a slow consumer grows memory for the Run's duration. Runs
  dispatched from the follow-up queue keep only the newest 256 events.
- **One response in total.** Apart from the per-event limit, the size of a
  streamed response and of accumulated tool-call arguments is not capped. Model
  output token limits and the Host's request policy bound them.
- **Request timing.** Adapters set no deadline or retry of their own; the URL
  loading idle timeout applies. `ProviderRequestPolicyProvider` (opt-in) adds
  idle budgets, a total deadline and bounded retries. Its idle budgets count
  decoded output only, unless `idleCountsWireActivity` is set: then received
  bytes that decode to no event (keep-alives, encrypted or signature-only
  reasoning) also restart them.
- **Non-cooperative executors** pin their lease and Session as described above.

## Data at rest

The segmented file journal stores conversation messages, tool arguments, tool
outputs, receipts and mutation intents as plaintext JSON. Images are stored
once per digest in the store's `images/` directory as their original bytes.
The SDK offers no encryption and no redaction hook for journal content; the
journal store protocol is internal, so a Host cannot substitute an encrypted
store. (The audit exporter's `AuditExportRedactor` applies to exported audit
batches only, not to the journal.)

On POSIX systems:

- Journal files and the writer lock are created with mode `0600` and opened
  with `O_NOFOLLOW`.
- Directories are created with the platform default mode, normally `0755`
  after the usual umask, so other local users can list file names. The Host
  should create the journal inside a directory only its user can enter.
- Each frame carries a SHA-256 digest. It detects torn or damaged writes; it is
  not a signature and does not stop someone who can write the files.

Durability: before a commit is acknowledged, the written file and its
directory are synchronized with `fsync`, and an unpublished tail is truncated
on open. On Linux, `fsync` asks the device to make the data stable. On Darwin
(macOS, iOS), `fsync` passes the data to the drive but does not force the
drive's own write cache to permanent storage; only `F_FULLFSYNC` does, and the
journal does not use it. An acknowledged intent or settlement therefore
survives a process crash on every platform, but on Darwin it may be lost on
power loss or an operating-system crash. On Windows, publication uses
`MOVEFILE_WRITE_THROUGH` after flushing the file; there is no directory sync.

## Host executors remain the trust boundary

The SDK can:

- Refuse to open a mutation Session without durable journal storage
- Admit a mutation intent before the executor runs
- Validate receipts and refuse to settle on mismatch
- Keep scheduler isolation for shared resources
- Keep provider adapters from executing host tools

`.durable` on a journal means a persistence backend is bound that can keep an
admitted intent across process death. The SDK still has to write the intent
and can still fail that write. Hosts must handle persistence errors, including
`commitUnknown`: an uncertain intent never authorizes the executor, the
journal handle refuses further work, and the Host must reopen the store and
inspect it before retrying.

The SDK cannot:

- Make an untrusted host executor honest
- Prove an external system changed without a receipt from that system
- Prevent a host from implementing `AgentTool.execute` incorrectly
- Detect instructions hidden in tool output, context or images
- Replace operating-system sandboxing, secrets handling, disk encryption, or
  user consent

Product UI, platform services, file systems, and other host executors stay outside Core.
WorkspaceAgent is a Reference Host that demonstrates the contract; it is not a
security boundary for other apps.

## Host obligations checklist

- [ ] Use one `ToolScheduler` for every Session that can touch the same objects.
- [ ] Declare in `resourceRequirements(for:)` every resource a mutation may
  touch (or a covering name, or `.global`), with one byte-exact spelling per
  object.
- [ ] Make every executor respond to cancellation; an executor that does not
  holds its lease and its Session until it returns.
- [ ] Recheck mutable state inside the executor (versioned reads or
  conditional writes) when authorization ran before the lease.
- [ ] Return receipts only from trusted observations of the external system.
- [ ] After `commitUnknown`, stop, reopen the store and inspect it before
  retrying.
- [ ] Reconcile or abort every mutation that needs reconciliation
  (`recoverPendingMutations`); until then the same operation is refused. Wait
  for the Run's physical drain before reconciling.
- [ ] Reconcile with output that matches the tool's output schema and size.
- [ ] Abort a mutation only after confirming it had no external effect.
- [ ] Keep `operationID` stable across retries of one logical operation, and
  distinct for operations that are meant to happen twice.
- [ ] Put content written by someone other than the user or the Host in tool
  results, not in context materials, Host notes, Run inputs or steering.
- [ ] Write Host-call notes and `RecoverableToolError` messages in Host code;
  never relay them from an embedded panel or the model.
- [ ] Consume Run events promptly, or use bounded consumers.
- [ ] Set `authorizationWaitLimit` and `leaseWaitLimit` when the Run deadline
  is too long a wait.
- [ ] Wrap adapters in `ProviderRequestPolicyProvider` or set transport
  timeouts when the defaults do not fit.
- [ ] Place the journal in a directory only the Host's user can enter, and use
  disk encryption when its contents are sensitive.
- [ ] On Darwin, do not rely on journal durability across power loss.
- [ ] Bind a concrete provider, model and parameters per Run; treat catalog,
  decision and model output as advice.
