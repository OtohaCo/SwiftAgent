# SAI-072 Independent Review

Date: 2026-09-20
Baseline: `cb8cd022d5ad08f5739d714057200826aa523c95`
Candidate: `bc19c62` (SAI-072 implementation and remediation)
Method: fresh read-only source review plus focused regression tests
External model: not invoked; this record does not claim a Claude review

## Scope

The review covered the dynamic binding, catalog, cache, projection, routing,
continuation, Session preflight, steering, and related test changes. It also
checked that the existing mutation, drain, and provider boundaries remained
unchanged.

## Findings and disposition

| Severity | Finding | Disposition | Evidence |
| --- | --- | --- | --- |
| P1 | Cancellation could be observed after preflight but before the user turn was committed. | Accepted and fixed. | `AgentSession.startRun` now checks cancellation after preflight and every awaited journal pre-commit step. `cancellationAfterNonCooperativePreflightDoesNotCommitUserInput` passes. |
| P1 | Provider catalog pagination replaced a configured endpoint query, and the query was absent from the cache scope. | Accepted and fixed. | OpenAI and Anthropic pagination preserve base query items; endpoint scope includes the non-secret query. Pagination and scope assertions pass. |
| P2 | A Host candidate could pair a binding with a catalog entry for another model or deployment. | Accepted and fixed. | `HostModelRouter` rejects model/provider/deployment scope mismatches before manual or automatic selection. `catalogEntryMustMatchBindingIdentity` passes. |
| P2 | Catalog refresh cancellation marked a last-known-good snapshot stale. | Accepted and fixed. | Cancellation clears only the in-flight generation and retains the fresh snapshot. `cancelledRefreshRetainsLastKnownGoodAsFresh` passes. |
| P2 | Steering and tool completion reused the initial projection revision for later requests. | Accepted and fixed. | `AgentLoop` advances local projection revision and context epoch whenever the request history changes. `steeringAdvancesTheProjectionCoordinatesBeforeTheNextRequest` passes. |
| P2 | Duplicate tool-call IDs in one assistant message could be folded by a Set and later trap dictionary construction. | Accepted and fixed. | Core pair validation rejects duplicate IDs; resolved read-only span grouping also rejects duplicates. `duplicateToolCallIDsAreRejectedBeforeProviderExecution` passes. |
| P2 | Invalid Host candidate IDs could be hidden as a generic decision failure and fallback. | Accepted and fixed. | Candidate IDs are validated before a DecisionProvider call and produce `invalidCandidateID`. `invalidCandidateIDFailsBeforeRemoteDecision` passes. |

## Rejected or not applicable

- No evidence showed a new mutation, Evidence, Receipt, Journal, or drain
  correctness regression.
- No provider-specific continuation was widened by the routing example.
- No external Claude/Fable review was claimed because no external model result
  was available in this review pass.

## Verification

Focused tests pass for `AgentModelBindingTests`, `AgentSteeringTests`,
`ModelCatalogCacheTests`, `ModelCatalogProviderTests`, and
`HostModelRouterTests`. The complete Swift package test suite also passes with
live-provider flags explicitly disabled. Script-level and hosted CI evidence is
recorded separately in the task acceptance record. The post-review remediation
commit adds no new SwiftAgent library product or public symbol; it only tightens
validation, cancellation, cache, projection, and routing behavior.
