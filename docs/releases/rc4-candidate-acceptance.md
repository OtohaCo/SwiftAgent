# RC4 candidate acceptance record

Status: PR #22 candidate under independent review. This is not a release or
final-main qualification. The reviewed base is `44e48f0783be0c467d45ac4b7d9f98c42e01718e`;
the original queue head was `1f573252ec65a8cd897b5ec37f2c638ae8f521b2`.
Record the final PR head, tree and exact CI checkout in the PR review before a
merge decision. Recheck the resulting `main` and production Hosts separately.

## Four frozen RC4 feature slices

| Slice | Candidate contract and evidence boundary |
| --- | --- |
| Segmented Journal | Indexed, incrementally committed schema-2 durable facts; trusted intent, settlement and recovery remain in the Journal. Schema 1 and older formats have no automatic migration. |
| Context Pipeline | Request-only sourced projection with per-request budget; summary and excerpt are derived views, not formal messages or Evidence. |
| Scoped Capability Binding | Run-bound tool/backend/resource snapshot; revocation blocks new final execution admission, while in-flight physical drain retains its owner. |
| Durable Follow-up Queue | Stable input identity, FIFO receive, combined queued-to-Run/formal-input publication, explicit Host dispatch and inspection after uncertain admission. |

The [public queue fixture](../../Examples/ExternalClient/Sources/FollowUpQueueFixture/main.swift)
uses synthetic Providers and a temporary-file mutation. The external client
test `queuedRunIsDeliveredToTheSinglePublicEventObserverAndExecutionReport`
observes a real queued Run through its public handle, reduces one event stream,
and keeps its validated receipt and tool completion distinct from a deliberately
malformed final presentation. A separate blocked Host observer test confirms
settlement can complete while observation waits, but dispatcher drain and the
sole-user store close wait for that observer's actual exit. The queue, Journal, Context, Capability and
ModelBinding regressions establish the local SDK boundary; none substitutes
for live Provider, OS sandbox, power-loss or production Host qualification.

## Cross-module closure to verify on the final candidate

- Receive future input during an active Run without changing its formal
  conversation or projection revision; dispatch later with freshly approved
  model, Context and capability bindings.
- On revocation or cancellation, retain committed tool and mutation facts;
  an abnormal or incomplete predecessor pauses future FIFO admission.
- `stop()` prevents new dispatch, and `waitForDrain()` covers the actual
  resolver, startup, inspection I/O, Run, observer and lease release. A closed
  isolated store can reopen without automatically running queued or uncertain
  admitted inputs. Host inspection explicitly decides when later inputs may run.

## Release decision still separate

- Schema 2 is a breaking format change. Schema 1 and legacy Journal files are
  rejected without conversion. Creating an empty store for an old task does
  **not** preserve its operation-domain deduplication and must not be treated
  as a migration or safe resume.
- Queue input identities and terminal mutation identities are retained for the
  operation-domain lifetime. Packing reclaims redundant process files but
  cannot promise fixed total disk usage.
- Capture exact-head local macOS and concurrency gates, queue/process and
  ExternalClient fixtures, and hosted macOS/Linux/Apple push and PR checkout
  SHA/tree in PR #22. Re-run after any code change. A merged-main check is
  required later; green candidate CI is not a published RC4 approval.
- No release tag, production store cutover or Host dependency change is
  authorized by this record.
