# RC4 candidate acceptance record

Status: PR #22 merged as `3e9c57ff9f4857430d0bee1ecaa2314d558dcb5f`.
This record describes the reviewed candidate, not final-main or live
qualification. The reviewed base is `44e48f0783be0c467d45ac4b7d9f98c42e01718e`;
the original queue head was `1f573252ec65a8cd897b5ec37f2c638ae8f521b2`.
The PR records its final head, tree and exact CI checkouts. Recheck the
release-metadata main commit and production Hosts separately.

## Four frozen RC4 feature slices

| Slice | Candidate contract and evidence boundary |
| --- | --- |
| Segmented Journal | Indexed, incrementally committed schema-3 durable facts; trusted intent, settlement and recovery remain in the Journal. Schema 1 and unreleased schema 2 have no automatic migration. |
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

## Independent review closeout boundaries

- The preserved `/tmp/rc4-review-probe.diff` originally exposed a withdrawn
  resolver head that stalled later FIFO input. Formal barrier tests show that
  only the selected, reliably withdrawn store/Session/input/ordinal can advance
  after startup cleanup; pause/stop, a real Journal error, `commitUnknown` and
  other conflicts do not become silent withdrawal results.
- A poisoned handle can close after its dispatcher, Run, observer and accepted
  I/O drain. Closing decides no uncertain commit. The old Session remains
  unusable; a new owner reopens and inspects the published root. Failed close
  retains the old writer lock for an explicit retry.
- Removing one necessary index from a closed synthetic store previously made
  Session/queue/mutation facts look absent; operation identity could then
  reach a second real disposable-file execution. The schema-3 index witness
  and stable position commit ID make these reads/writes fail explicitly while
  preserving legitimately unpublished keys. Normal maintenance, retained
  messages, queue associations and settled mutation state are regression
  checked with the damaged index restored after inspection.
- The earlier `793403d` push/PR results qualify that historical schema-2
  candidate only. PR #22 records the schema-3 closeout SHA/tree, local gates,
  Release count benchmark and hosted checkout evidence. Its checks do not
  qualify a later release-metadata commit on `main`.

## Release decision still separate

- Schema 3 is a breaking format change. Schema 1, unreleased schema 2 and legacy Journal files are
  rejected without conversion. Creating an empty store for an old task does
  **not** preserve its operation-domain deduplication and must not be treated
  as a migration or safe resume.
- Queue input identities and terminal mutation identities are retained for the
  operation-domain lifetime. Packing reclaims redundant process files but
  cannot promise fixed total disk usage.
- Capture release-metadata main's local macOS and concurrency gates,
  queue/process and ExternalClient fixtures, hosted macOS/Linux/Apple push
  checkout SHA/tree, and a clean remote SwiftPM consumer in the release
  record. PR #22's green candidate CI is not final-main release approval.
- No release tag, production store cutover or Host dependency change is
  authorized by this record.
