# ADR 0009: Audited Authorization

Status: accepted for RC6 implementation

The Host owns the authorization decision. SwiftAgent captures, binds, enforces
and records it in the existing AgentLoop. A Receipt remains execution evidence;
it is not an approval document. Provider network egress is outside this feature.

`AgentConfiguration.authorization` defaults to `legacy`. `requiredAudit` is a
Host factory configuration, with no per-Run downgrade. It requires a schema-5
durable Journal, a Host authorizer and bounded identity context before Provider
contact or candidate input publication. It covers every model tool, including
read-only, runtime-defined and `authorization: .notRequired` tools. Required
tool-domain authorization remains an additional check.

The SDK gives each received call instance a new invocation and proposal ID.
Model call IDs are untrusted correlation labels. The versioned action digest
binds the existing canonical JSON semantics, frozen definition and declared
implementation versions, resources/revisions, material versions, backend and
credential generation, store/domain, Session/Run and capability scope. The
Host must implement immutable inputs, versioned reads or conditional writes;
a digest cannot freeze a mutable or malicious executor. An archived decision
contains no process-local permission and cannot be decoded to regain one.

Four append-only typed facts describe proposals, authorization evaluations,
execution dispositions and references to the existing output/Receipt/settlement
ledger. Host decision time, SDK observation time and reliable publication
sequence remain separate. Neither clocks nor local digests are signatures,
trusted timestamps or protection against an administrator rewriting the store.

Short Journal transactions publish: received proposal; actual Host decision;
authorization application plus mutation intent (or read-only dispatch); and
result reference plus existing settlement/checkpoint. No transaction or resource
lease spans human/network authorization. Final admission uses the existing
scope coordination and a process-local bounded permit. `dispatchPrepared`
means preparation only. Missing executor observations after a crash do not
prove no effect. Unknown commits require reopening the real root; pending
effects use the existing reconciliation/no-effect-confirmation APIs.

Schema 5 is explicitly selected at store creation and includes schema-4
admission rejection support. Schema 3/4 are never upgraded in place. Old
readers reject the actual format version at open. Typed audit payloads,
association indexes, witnesses and exporter checkpoints share CURRENT and its
transaction domain with execution facts. Audit-only commits do not change
conversation revision. Ordinary commits append bounded increments; audit
history and the referenced mutation identities are retained during maintenance.

Throwing Host-only queries use bounded pages, association indexes and a fixed
high-water mark. Cursors bind store and filter. Restricted raw payloads are
separate from the regular view. Explicitly started exporters read committed
facts, apply deterministic redaction and send versioned batches to a Host
`AuditExportSink`. Matching prefix ACKs advance a durable checkpoint. Stable
store/record IDs allow receiver deduplication under at-least-once delivery.
Destination/filter/redaction changes use a different checkpoint. Local commit,
not remote ACK, is the execution gate. Configured backlog pressure refuses new
protected work while settlement and cleanup retain their owner and capacity.

Run and exporter owners retain noncooperative authorization, sink and cleanup
work until physical exit; cancelled waiters do not release that ownership.
Export is disabled until explicitly started. There is no automatic migration,
memory fallback, arbitrary Journal backend, automatic deletion or remote/local
distributed transaction. JSONL is an archive view, not a recoverable backup.
