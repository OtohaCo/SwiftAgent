# SwiftAgent Evidence

last-verified: 2026-09-18

Evidence binds a resource reference to a trusted observation. It carries an open
namespace, opaque ID, issue/expiry dates and JSONValue metadata. The engine never
interprets a namespace as a business domain.

```swift
import AgentModels
import AgentTools
import Foundation

func observedDocument(_ id: String, revision: String) -> Evidence {
    Evidence(
        namespace: "cad.document", id: id, issuedAt: Date(),
        expiresAt: Date().addingTimeInterval(60),
        metadata: ["revision": .string(revision)]
    )
}

func requireCurrentDocument(_ id: String, revision: String, context: ToolContext) async throws {
    try await context.requireEvidence([
        EvidenceRequirement(reference: .init(namespace: "cad.document", id: id),
                            metadata: ["revision": .string(revision)])
    ])
}
```

## Publication and Requirements

A tool returns observations in `ToolResult.evidence`. The registry publishes them
only after typed output encoding, output schema validation and invocation checks.
Publication binds Session and Run IDs from the runtime context. Neither model text
nor a JSON field named evidence creates a trusted observation.

For an evidence-bound tool, declare `ToolPolicy.evidence == .required` and implement
`evidenceRequirements(for:)` from the typed input. An empty resolver fails closed.
The runtime checks requirements before authorization and again after an
authorization wait. Missing ledger, missing reference, expiry, wrong scope and
metadata mismatch prevent execution. Metadata requirements match exact JSON values
for the supplied keys; other observed metadata is allowed.

ToolContext exposes identity-bound `requireEvidence` for read-only validation.
Use `resolveEvidence` with the same requirements when a host tool needs trusted
metadata. It returns immutable observation values in requirement order, after
validating the whole batch inside one ledger actor call. Missing or invalid
members throw without returning a partial batch. Reading does not publish or
refresh evidence, and modifying the returned array cannot change the ledger.

Resolution is a snapshot, not an ongoing authorization. After subsequent waits,
tools must recheck requirements before relying on freshness for an operation.
Its writable ledger handle is package-only, so host tools cannot bypass publication
by writing through the runtime context. Standalone EvidenceLedger remains available
to trusted host infrastructure and tests; tools should publish through ToolResult.

## Scope and Freshness

The default requirement is `sameRun`. `sameSession` explicitly permits the latest
observation from another run in that Session. AgentSession owns one ledger; each
independent low-level AgentLoop invocation creates a fresh ledger. Replaying
ModelMessage history does not recreate trusted evidence.

References and metadata comparisons preserve exact Unicode distinctions. A batch
with duplicate references or invalid observations is rejected before any write.
Issue dates must be finite and not in the future; expiry must be finite, later
than issuance and later than publication time. Requirements reject evidence at the
expiry boundary. An invalid clock fails closed.

Only the latest accepted observation is used for each Session/reference. Older
issue timestamps cannot replace it; equal timestamps use the last publication.
Expiry or metadata mismatch never falls back to a previous version. The engine
does not infer ordering from business revision values; adapters own that policy.

Runtime publication carries the invocation deadline and checks cancellation inside
the ledger. Late output from a cancelled or timed-out tool cannot publish through
the registry. Scope/freshness validation is not a mutation receipt, durable intent,
or reconciliation mechanism. The mutation gate remains separate.
