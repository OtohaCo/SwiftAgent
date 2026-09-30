# Audited Authorization (RC6 candidate, unreleased)

last-verified: 2026-09-30

**The Host owns the authorization decision. SwiftAgent binds, enforces and
records that decision. The Receipt remains evidence of execution, not an
approval document.** This opt-in feature is absent from `1.0.0-rc.5`.
[中文接入说明](swift-agent-authorization-audit.zh-CN.md).

## Choose the mode at the Host factory

`AgentConfiguration.authorization` defaults to `.init(mode: .legacy)`. Existing
Host integrations keep their tool authorization and execution behavior. Legacy
does not promise complete authorization audit, even on a schema-5 store.

`requiredAudit` requires a writable, durable, explicitly audit-capable Journal,
a Host `AgentAuthorizer`, and bounded `AgentAuthorizationIdentity`. Missing
configuration fails at Session construction; closed, poisoned, damaged or
backlog-limited storage fails again at Run/follow-up admission **before candidate
input is committed or a Provider is contacted**. There is no memory fallback,
automatic downgrade or per-Run mode override. Model output, Skills and tool
parameters cannot change the Agent's factory configuration.

Every model tool call is covered: mutation, read-only, runtime-defined and
`authorization: .notRequired`. Required `tool.authorize` remains an additional
domain check. Put human confirmation in the centralized authorizer; keep tool
checks for domain constraints so two confirmation dialogs are unnecessary.
Tool authorization alone does not cover Provider network egress.

## Minimal public Host integration

The following definitions are compiled in the separate
[HostIntegration.swift](../../../Examples/ExternalClient/Sources/EnterpriseAuthorizationFixture/HostIntegration.swift)
client source. A Host can pass
its own existing provider, tools, identity and directory:

```swift
import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation

struct ExampleEnterpriseAuthorizer: AgentAuthorizer {
    let allowedToolNames: Set<String>
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
        AuthorizationDecision(request: request,
            outcome: allowedToolNames.contains(request.toolDefinition.name) ? .allow : .deny,
            subject: .init(issuer: "example-host", subjectID: "local-rule", type: .automatedPolicy),
            policy: .init(id: "controlled-tools", version: "1", ruleReferences: ["exact-current-request"]),
            validFor: .seconds(30), reasonCode: "host_rule")
    }
}

func makeAuditedSession(directory: URL, operationDomain: String, model: ModelID,
                        provider: any ModelProvider, tools: [any AgentTool],
                        authorizer: any AgentAuthorizer,
                        identity: AgentAuthorizationIdentity) throws -> (AgentSession, AgentJournal) {
    let journal = try AgentIncrementalJournal.create(at: directory,
        operationDomain: operationDomain, supportsAuthorizationAudit: true)
    let agent = try Agent(model: model, provider: provider, tools: tools,
        configuration: .init(authorization: .init(mode: .requiredAudit,
            authorizer: authorizer, identity: identity)))
    return (try agent.makeSession(journal: journal), journal)
}
```

[Compiled source](../../../Examples/ExternalClient/Sources/EnterpriseAuthorizationFixture/HostIntegration.swift).
The allowlist above is a controlled example rule, not enterprise policy. The
Host authenticates identities, evaluates policy, verifies any external approval
and supplies non-secret backend/account/credential-generation identifiers.
`tenantID` and `projectID` label context; they do not isolate storage or authorize
access. For a simulated human decision, use `.human`, a stable issuer and user
ID, and confirmation tied to the **current** `request.actionDigest`. A display
name or model text saying “approved” is insufficient.

`AuthorizationRequest` has no public initializer and is not Codable. The runtime
builds it from the frozen prepared call. `AuthorizationDecision(request:...)`
copies its request ID, exact digest, scope and local policy generation. Codable
archives omit the process-local request challenge; decoding an old decision,
knowing its authorization ID or returning old JSON cannot recreate permission.
The Host must construct a fresh decision for each current request, even when it
consults an external approval service. `requiresUserAction` means **no current
permission**. Long approval waits belong to the Host; redispatch checks current
conditions and creates a new proposal/authorization, linked to the earlier
proposal when in the same Run. For a Host-managed redispatch, set factory
`AgentAuthorizationConfiguration.relatedProposalID` to the prior proposal ID
and restore the same Session/store. Startup validates this reference before
input/provider work; foreign Session/store references fail. The new request and
digest bind the lineage, and the old facts remain unchanged. This reference
never restores permission. Edits require a new call, never a rewrite of old facts.

## Directory, format and retained facts

The Host supplies `create(at:operationDomain:supportsAuthorizationAudit:)` or
`createAsync`; reopen the same directory with `open`/`openAsync`. There is no
SDK-selected production user directory, cache or `/tmp` fallback. The fixture
alone uses a disposable temporary directory.

Audit-capable creation selects **format schema 5**, including schema-4 bounded
admission rejection support. Ordinary creation remains schema 3; explicit
`supportsAdmissionRejections: true` alone remains schema 4. Schema 3/4 open
normally but refuse `requiredAudit`; no format is upgraded in place. The real
RC5 reader rejects schema 5 at `format.json`, including an empty store. A new
store does not inherit another directory's operation-deduplication facts.

The authoritative typed records are payloads in the existing managed Journal:
`segments/<storeID>_<segmentID>.seg`, retained `state/*.pack` and, for larger
frames, `blobs/<shard>/*.blob`. `CURRENT` selects the root/layout and committed
positions. `audit-records`, `audit-groups`, `audit-members`, `audit-exports` and
`witnesses` are managed indexes, not replacement journals. There is no separate
`audit.jsonl` authority and no arbitrary Host `saveAuditRecord` callback. Do not
edit any of these files. Missing published indexes/witnesses fail as corruption,
not an empty approval set. Ordinary conversation text cannot create typed facts.

All Sessions that share mutation deduplication use the same store/operation
domain and shared `ToolScheduler`. Project labels, export destinations or new
scope instances do not partition coordination or change `operationID`.

| Fact | Meaning |
| --- | --- |
| Proposal `.received` | Complete bounded payload received, or explicit limited diagnostic for abnormal ID/oversize input; raw data is independent of formal conversation |
| Proposal `.prepared` | Existing `JSONValue` normalized arguments, actual definition/policy, declared versions/materials/resources/backend, expectation and exact digest |
| Authorization | Enterprise outcome and tool-domain check separately; Evidence rejection is enterprise `notEvaluated`; timeout/error is `incomplete`, not a fabricated deny |
| Disposition `.dispatchPrepared` | Decision application was durably published; for mutation this shares the commit with intent; this is not executor entry |
| `.runtimeAdmitted` / `.executorObserved` | Local final admission vs observed executor entry; these are distinct facts |
| `.notExecuted` / `.interrupted` / `.uncertain` | Known pre-entry rejection; observed read interrupted; unresolved mutation follows existing ledger/reconciliation |
| Result reference | Existing settled Receipt/output, legal read-only output, replay, reconciliation or no-effect confirmation; no second success state machine |

Every record has version, stable record ID, audit sequence, shared Journal record
sequence, scope links and a SHA-256 digest. Links include store/domain,
Session/Run, runtime-generated invocation and proposal IDs, untrusted model call
ID, and available authorization/request/operation IDs. `operationID` keeps its
existing idempotency meaning. Host decision time, SDK observation time and
publication order are separate; clocks are not trusted timestamps and ordinary
local digests are neither signatures nor administrator-tamper protection.

## Binding, admission and recovery

`AgentTool.authorizationBinding(for:)` has a default; implement it to supply
actual definition/implementation versions, resource revisions, non-secret
backend/account generation, and **immutable material ID/version/content digest**.
The action digest covers these declarations, existing normalized JSON semantics,
actual definition/policy/resources/Receipt expectation, Host identity and
Session/Run/store/capability scope. Mutable file paths alone are insufficient.
Runtime checks declarations again under the resource lease and immediately
before executor entry. The fixture changes real selected attachment content,
recipient, revision and backend identity after approval and rejects the old
permission.

The SDK cannot freeze an arbitrary Host backend: use immutable prepared data,
versioned reads or conditional writes inside the real executor to close its own
check/use race. Declaration equality does not sandbox a malicious executor.

Short commits publish proposal, actual decision, application plus intent, then
existing settlement/checkpoint plus result reference. Network/human approval,
tool execution and export never hold a Journal commit lock. Audited approval
also occurs before the tool resource lease. Final admission coordinates with
capability and `AgentAuthorizationScope` revocation/generation; deadlines use
`ContinuousClock`, never durable time-based permits.

`await scope.revoke()` refuses new final admissions and requests cancellation.
`advanceGeneration(to:)` invalidates outstanding requests and cancels their
Runs. If admission preceded revoke, the call is in flight and retains its
cancellation/settlement/drain owner. Remote policy changes are not instantly
observable locally; the Host performs online checks and forwards received
revocation generations. Multiple checks are not a cross-system atomic proof.

Proposal persistence failure starts neither its authorizer nor executor.
Decision/application failure never grants admission. A `commitUnknown` poisons
the handle: drain, close, reopen the real directory, inspect the selected root,
and use existing mutation reconciliation. Do not retry the business action
blindly. `dispatchPrepared` or absent durable entry observation after a crash
does not prove no effect. An existing intent is never erased/aborted on timeout
or cancellation. Host-confirmed no effect uses the existing explicit API.

Settled replay still evaluates current enterprise and required tool access,
obtains final admission and references the original Receipt/output. It has no
new executor observation or external effect. Presentation, observer or export
failure after settlement does not repeat execution. Audit writes do not advance
conversation revision or manufacture tool results for unexecuted proposals.

## Trusted, throwing, bounded queries

`journal.auditRecords` is an administration API, never an automatically registered
model tool. The Host authorizes viewing and isolates its security domains. The
regular view omits raw/normalized arguments, definitions/materials/resources,
Receipt identities and canonical mutation identity; it retains bounded Host
identity/decision metadata, which can itself be sensitive. Use restricted
queries only for an authorized operator, not default logging.

```swift
func inspectRun(_ journal: AgentJournal, runID: UUID) async throws {
    let query = AuditQuery(runID: runID)
    var cursor: AuditCursor?
    repeat {
        let page = try await journal.auditRecords(matching: query, limit: 50, cursor: cursor)
        for record in page.records {
            switch record.fact {
            case .authorization(let a): print(record.sequence, a.layer, a.status)
            case .disposition(let d): print(record.sequence, d.state)
            case .result(let r): print(record.sequence, r.kind, r.sourceRunID)
            case .proposal(let p): print(record.sequence, p.stage, p.reconstructable)
            }
        }
        cursor = page.nextCursor
    } while cursor != nil
}
```

Enterprise `.allowed` or `.denied`, `.notEvaluated` and dispositions/result kinds
answer allow/deny/not executed/unknown/replay independently. Query by
`sessionID`, `runID`, `invocationID`, `authorizationID`, `operationID` or
`logicalOperationID`; supplied filters are ANDed. Use
`includeRestrictedPayload: true` to retrieve the original bounded raw proposal
and normalized prepared fact through their shared `proposalID`. An authorization
filter starts at preparation; query `proposalID`/invocation to include reception.

Pages are 1–100 results with at most 400 inspected records; combined filters can
yield an empty page with a non-nil cursor. Follow `nextCursor`. The fixed
high-water mark excludes later commits. `afterExclusiveSequence` skips already
seen global audit sequences; a cursor binds store, query, payload view and high
water. Mismatches throw; it is a position token, not an access credential.

## Host archive sink and explicit export

```swift
struct ExampleEnterpriseSink: AuditExportSink {
    let acceptDurably: @Sendable (AuditExportBatch) async throws -> Void
    func write(_ batch: AuditExportBatch) async throws -> AuditExportAcknowledgement {
        try await acceptDurably(batch)
        return .init(batch: batch)
    }
}
```

The Host closure chooses the destination, implements authentication/transport,
and durably deduplicates `(storeID, auditRecordID)` before ACK. The runnable
fixture supplies a local JSONL receiver that fsyncs accepted lines, loses one
ACK, resends and deduplicates. No cloud service or credential is built in.

Only `journal.startAuditExporter(configuration:sink:redactor:)` starts delivery;
passing configuration/credentials never starts it. One pass stops when caught
up or after bounded retries; starting a later pass is explicit. `stop()` requests
cancellation without requiring the whole backlog. `waitForDrain()` observes
physical exit. The exporter retains a Journal lease while its accepted reads,
network work or checkpoint commits still depend on it, including an uncooperative
sink after timeout. Cancelling a waiter releases only that waiter. Slow export
holds no mutation resource or commit lock and cannot block ordinary settlement.

Batches bind exporter/batch/store/destination/configuration/content version and
digest, plus contiguous global `firstSequence...throughSequence`. Matching
partial ACKs advance only the confirmed prefix. ACK loss resends the same batch;
record IDs remain stable after restart. Duplicate old-batch, out-of-range,
mismatched or stopped-owner ACKs never advance another range. `status().journalFailure == .commitUnknown` reports local checkpoint
uncertainty and requires reopen. At-least-once delivery requires receiver
deduplication; ACK is not authorization and cannot settle a mutation.

Configuration identity binds destination, filters, content and redaction
versions. Changing any under the same `id` refuses the old checkpoint; choose a
new ID and re-export from zero. Filtered batches may include no records while
acknowledging skipped sequences under that exact configuration. The optional
backlog policy measures that configuration's confirmed **global range**, not
remote acceptance of excluded records; the Host must choose suitable filters.

The standard exporter provides a **conservative summary**, not a complete
copy of the authorization record. Its redactor receives that same summary;
`AuditExportRedactor` does not receive the original `AuditRecord` or recover
fields removed by the SDK.

| Field | Trusted Host query | Standard export / redactor input |
| --- | --- | --- |
| store/record IDs, audit sequence, committed digest, UUID links | Retained | Retained |
| decision outcome, human/automated/service subject type | Retained | Retained |
| subject issuer and subjectID | Retained | Omitted |
| policy ID, version and rule references | Retained | Omitted |
| Host decision time and SDK observation time | Retained as separate values | Omitted |
| raw/normalized proposal and materials | Restricted query only | Omitted |
| outputs, Receipt/canonical operation identities, endpoints | Restricted query as applicable | Omitted |

Implement deterministic `AuditExportRedactor`, change `redactionVersion` when
behavior changes; throwing or output over 16 KiB stops without sending that
batch. Redaction changes only the archive view, never binding or canonical
history. The Journal itself is not encrypted or guaranteed free of sensitive
data; digests can also disclose correlations.

For an archive that needs selected subject, policy or time metadata, trusted
Host management code can paginate `journal.auditRecords` and explicitly project
those fields into a Host-owned schema/receiver. Ordinary queries already retain
those decision fields; retrieving them does not require restricted proposal
payloads. The compiled package-external
[`archiveSelectedAuthorizationMetadata`](../../../Examples/ExternalClient/Sources/EnterpriseAuthorizationFixture/HostIntegration.swift)
example selects only subject, policy ID/version and both distinct times, with
stable store/record IDs and the committed digest. The real fixture verifies both
that archive and the summary seen by a pass-through redactor and JSONL sink.

The Host owns access control, selection/destination schema versions, durable
receiver deduplication and its own confirmed position for that independent
archive. Keep a fixed query cursor during a pass, and advance the Host position
only after durable receipt. Do not use `AuditExportAcknowledgement` or the SDK
export checkpoint to claim receipt of extra fields omitted by the standard
batch. Selecting additional fields does not grant execution permission or make
either JSONL view a complete authorization-record copy or recoverable Journal
backup. An archive claiming full records must separately define, authorize and
validate its required fields and retention; this sample intentionally does not.

Optional `AuditBacklogPolicy(exportConfigurationID:maximumUnacknowledgedRecords:)`
refuses new protected work once its bound is reached. Local reliable commit is
the default gate, not remote ACK. Policy failure and disk pressure preserve the
settlement/cleanup path for admitted work; actual disk failure can still leave
unknown results. Upload failures never trigger business re-execution.

## Limits, ownership and retention

Per Run, at most 64 captured call instances; up to 32 active Runs per shared
authorization scope. Raw call arguments are capped at 64 KiB, encoded typed
records at 256 KiB and action material at 128 KiB. Abnormal IDs/names are bounded
to 512 UTF-8 bytes; an oversized proposal keeps only a 4096-byte prefix with
truncated/non-reconstructable flags and receives no execution permission.
Incomplete stream diagnostics do not promise complete fragment capture.
Subject/policy/reference identifiers are bounded to 512 bytes, explanation to
2048, decision archive to 16 KiB; materials ≤32 and revisions ≤64. Oversized
Host decisions are recorded as invalid without copying unlimited metadata.

The authorizer, tool workers and exporter have physical owners. Await Run drain,
scope drain where shared, exporter drain, and any dispatcher drain before Journal
close; logical completion alone does not prove cleanup exit. Uncooperative code
can retain those owners until it actually returns.

Maintenance retains typed facts, raw payloads, authorization links, Receipts,
outputs and mutation identities. Nothing is automatically forgotten after
upload. Disk costs grow with real work; local digests do not make these files
immutable against administrators. No SSO/IAM, generic policy language, multi-user
approval workflow, reusable approval token, automatic migration, arbitrary
Journal backend, remote/local transaction or all-Provider egress policy is supplied.
See [acceptance and performance](../releases/rc6-audited-authorization-acceptance.md).

Run the no-network external client:

```sh
swift run --package-path Examples/ExternalClient EnterpriseAuthorizationFixture
bash Scripts/ci-audited-authorization.sh
```
