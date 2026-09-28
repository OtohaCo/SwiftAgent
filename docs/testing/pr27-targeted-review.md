# PR #27 targeted review: durable rejection and operation scope

The review started from PR #27 head `01064b5d714f4f90c9060f405dc211882691d755`
(tree `fd53975be2c36cc15729a8302cbbfc21a5666308`), stacked on the
unchanged tests-only PR #26 head `5d792457a2b39f712e5f7279d51cb081c1080693`
(tree `13d503a16425886004fc82a7592589c97cbc8e0b`). Main and the RC4 tag
remained at `3f01599ef3d0923659226025a7d34d4144ed1800`. PR #27 had no
submitted reviews; its six macOS/Linux/Apple checks (push and PR) passed on the
starting head. No Host code or dependency was changed.

## Findings and repairs

| Location and trigger | Impact and failing evidence | Minimal repair and regression |
| --- | --- | --- |
| `AgentSession.record` submitted `.toolAdmissionRejected` with a checkpoint, but `SegmentedJournalStore.View.publish` copied only `recordCount` from `JournalStoreChange.records` into `BatchV2`. A Run with a real Evidence denial sent its event. | The formal assistant/error pair survived restart, but the separate trusted denial did not. The first `AdmissionRejectionPersistenceTests` could not compile its cross-process read: there was no persisted rejection query or payload. Ordinary `isError` text could not establish runtime provenance. | A schema-4 capable store writes a typed, call-bound denial in the same batch as the paired messages, with a witnessed index back to that batch. The package reader validates the identity; maintenance retains the indexed frame. A real Session/Run test and independent `JournalTestProcess` show the marker after close/reopen and after maintenance/GC. An ordinary read-only business error with identical wording has no marker. Before-append failure publishes neither fact; an after-`CURRENT` `commitUnknown` publishes both and stops continuation. |
| PR #27 version guide claimed the old reader would not understand rejection records, while the format was still schema 3. | The RC4 reader would ignore an unrecognized optional batch field or might open after later ordinary commits. A successful open alone would not establish compatible recovery semantics. | Only explicit `AgentIncrementalJournal.create(..., supportsAdmissionRejections: true)` reserves schema 4 and the rejection index. The unmodified RC4 binary rejects schema 4 at `format.json` before opening or appending, including a capable store with no rejection. Default creation stays schema 3. An opt-in Run on an existing schema-3 store fails before provider contact or input publication; no automatic migration or empty-ledger reset. The original RC4 source was built in an independent checkout for the matrix below. |
| `AgentSession.checkReplanningSafety` called unscoped `pendingMutations()` three times and tested `idempotencyKey.hasPrefix(operationID + "/")`. | The store enumerated all Session index entries; with 120 unrelated pending Sessions, three queries read 1,970,874 bytes, decoded 720 batches and took about 592 ms in a same-store local run. An operation `team/a/child` falsely matched `team/a`. `operationIdentityDoesNotConfuseNestedOrOverlappingIDs` failed before repair. The known Run/call fallback with no logical ID was initially classified as unknown and unnecessarily blocked unrelated work; `pendingWithoutLogicalOperationDoesNotBlockUnrelatedExplicitOperation` failed. | One current-root read checks the current Session, then an operation-specific witnessed index pointing to canonical pending mutation records. Identity uses the exact suffix `/<tool>/<canonical JSON>`; `/` inside the operation ID is preserved. Truly unknown/unparseable pending identities block conservatively; the known Run/call fallback has no cross-Session operation association. The same 120-Session, three-query fixture read 2,742 bytes, decoded 0 batches and took about 1.8 ms; these are local fixture costs, not production latency. Two Sessions with one logical operation remain blocked until both intents settle, including after restart. Faults before append and after `CURRENT` prove the index follows the published mutation root. |

## Whole-store RC4 reader matrix

`bash Scripts/verify-pr27-compatibility.sh RC4_CHECKOUT CANDIDATE_CHECKOUT`
builds two separate client binaries against the unchanged RC4 and candidate
sources. `Tests/JournalReaderCompatibility/verify.py` uses only disposable
stores and closed copies. It checks `open`, Session checkpoint and formal
messages, pending and mutation state, maintenance status, append on copies,
and root/file/identity changes. The schema-4 marker itself is read by an
independent candidate `JournalTestProcess` in the focused test.

| Store producer and state | New reader | Original RC4 reader | Disk and recovery conclusion |
| --- | --- | --- | --- |
| RC4 ordinary schema 3 | Open, restore, read, append on a copy and maintain: PASS | Producer | Root and content change on append; store identity remains stable. |
| Candidate default ordinary schema 3 | Producer | Open, restore, read, append on a copy and maintain: PASS | Default disk encoding and ordinary recovery remain compatible. |
| Candidate schema 4 capable, no denial yet | Open/read: PASS | `unsupportedFormat` at open and append: expected refusal | Feature reservation itself is a disk compatibility boundary. The refused copy is unchanged. |
| Candidate schema 4 after real denial | Open, restore/read, maintain, reopen and read typed marker: PASS | `unsupportedFormat` at open and append: expected refusal | The old reader does not silently treat a rejection as an ordinary tool result. Its refused copy retains the original root, identity and file digests. |

Source compatibility is separate: adding public `AgentEvent`, `AgentJournalEvent`
and `AgentSessionError` cases can break exhaustive Swift switches even with the
default policy disabled. Disk compatibility is determined by the format at
creation. Recovery semantic compatibility is established only for schema-3
ordinary stores; schema 4 is intentionally rejected by RC4. There is no
in-place upgrade or downgrade path for an existing RC4 store. A Host must
choose a new store and reconcile any outstanding effects before using the
opt-in policy in its own domain.

## Preserved behavior and limits

The default ScriptedProvider control still fails closed at the Evidence check.
With explicit opt-in and a capable store, strict T1 makes four model requests,
one search and one settled mutation; T2 makes five requests, two searches and
one settled mutation. Both use one Run, no Host retry, and zero authorization,
intent or executor entries for X. The correction's A still passes the full
admission and Receipt path. Authorization/executor errors of the same public
type, already settled or unresolved effects, scope revoke, cancellation,
deadline, budget, multi-call batches, steering, context projection, stable
message IDs and drain remain in the targeted suites and full gate. The
operation index is a lookup over the canonical mutation ledger, not a second
effect record; repeated reads are not a global atomic no-effect proof. Durable
admission still blocks uncertain or duplicate execution.

The provider mapping fixtures cover OpenAI, Anthropic and DeepSeek with
reasoning disabled. They do not qualify all DeepSeek thinking/continuation
modes. Real LLM correction rates, music recommendations, point-to-play p50/p95,
device playback and production Host integration are **NOT RUN**.
