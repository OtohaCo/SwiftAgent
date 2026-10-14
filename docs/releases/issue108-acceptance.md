# Issue #108 — incomplete native-turn handoff acceptance

Status: prepared post-RC6 SDK increment; no new tag or Release. This page records
source and local evidence. The closing acceptance report on [issue #108](https://github.com/OtohaCo/SwiftAgent/issues/108)
and its linked PR checks record remote head/merge identity and actual CI results.

## Source and environment

- Issue: https://github.com/OtohaCo/SwiftAgent/issues/108
- Baseline main: `a7940ae0286c7accef4aef8647919c57c042b8b9`;
  tree `e29e6bce80098cd3c49ea61a6a2c55d26a2ef2e8` (published RC6, unchanged).
- Implementation: `89490abf4bf0dd0d04795f945c18cbec9a11d4dd`;
  tree `cef91aeab65c6b88950e18db63805f85a1171d3f`.
- Clean local core, iOS and external-client gates run on the implementation commit.
  Remaining local script stages may identify this later documentation-only head;
  Sources, Tests, Scripts and package inputs are identical. Exact-head hosted CI
  is required separately. PR head is distinct from the implementation SHA.
- macOS 27.2 arm64, Xcode 27.0 (`27A266a`), Apple Swift 6.4
  (`swiftlang-6.4.0.34.1`). Swift 6.4.1 was not installed or qualified here.

## Behavior and boundary

The old completed-only handoff API remains unchanged. The required
`allowingIncompleteTurn: true` overload uses a separate closed-turn proof,
requiring real durable admission/terminal, physical ownership release, empty
pending state and legal tool pairing. Publication rechecks the same evidence in
its transaction. It retires request authority; canonical messages, opaque signed
bytes, execution/receipt facts and the original logical terminal remain unchanged.
It sends no HTTP request, admits no synthetic input and executes no tool.

The new path requires opt-in schema 14. Named synchronous/asynchronous factories
preserve existing creation function references. Exclusive offline schema 12/13
upgrades retain store identity and file references, using bounded FORMAT/CURRENT
recovery. Default schema 3 and existing formats remain unchanged. RC6 readers
reject schema 14 before reading/appending/maintaining. No downgrade or implicit
migration is provided. See the handoff and versioning guides for Host call order.

Future requests/reopen validate the frozen target model, origin, root and registry
(definitions, policy and initial/deferred declarations). Legitimate deferred
expansion within a Run remains valid. Read-only `conversationControlState` is
advisory, never a substitute for Core validation or drain/settlement.

## Targeted RED/GREEN and failures

The initial Swift File Journal test compiled against completed-only behavior and
failed at runtime with “requires a persisted completed Run and no pending mutation.”
The excerpt in `issue108-evidence/runtime-red.log` identifies design-only HEAD and
dirty test status. Subsequent staged tests exercised the explicit new opt-in path;
these development GREEN runs were dirty and are not substituted for clean full CI.

- Core: 10 test functions, including max-output, failed/cancelled admission,
  real mutation reconciliation/fresh actor, unchanged-head metadata races,
  definite failure/commitUnknown, cancellation/deadline/revocation with late
  projection, four target mismatches, missing proof/pairing/control refusals,
  and unrelated Session commits/maintenance.
- Storage: 5 new test functions, including schema 12/13, four actual SIGKILL
  cases at FORMAT/CURRENT boundaries, altered/missing target refusal, and
  nested 11→12→14 recovery after deleting ancestral root files. Existing format
  and handoff tests remain in the full suite.
- Anthropic: actual Swift encoder/HTTP replay for max_tokens, error after admission
  and held-transport cancellation; old native checkpoint/reminder retired, changed
  target model/origin/registry, exact canonical/terminal preservation and reopen.
- External client: public-only fixture with local signed-thinking payloads,
  truncation, upgrade, zero handoff HTTP/tool execution, new deferred expansion,
  exactly one actual tool execution and no duplicate execution after reopen.
  Seven public client tests also compile exact old/new function references.
- Reader gate: old default/schema12/schema13 positive reads/appends; 24 actual
  immutable-RC6 reader refusals across empty/populated/upgraded schema14 stores,
  before/after maintenance, with byte-for-byte unchanged files.

The first reader gate failed because its file-positive client used the ordinary
file-rejecting append binding (`unsupportedCapabilities`, rawValue 64). The fixture
now explicitly describes file input; one corrected gate passed. Both logs remain.
Four development compile failures were corrected before bounded reruns: omitted
internal tools argument, actor await in a test assertion, erased tool array type,
and a nil nonoptional control-state argument. They are not runtime RED evidence.
No test was deleted or weakened to obtain GREEN. Raw compiler/stage evidence stays
in `.ci-logs/issue108` and `.ci-logs/stages`; stable excerpts are included here.

## Complete gates and review

At documentation preparation, clean implementation core build/full tests
(1,176 test functions, exit 0), iOS cross-build, external client (46 primary test
functions), deterministic context/native/queue/run-record examples, provider
qualification fixtures (42 tests), AppleChat tests (32), AppleChat iOS build,
dynamic routing (21), replanning/decision regressions and execution reporting
acceptance had passed. The remaining checks were still running or awaiting hosted CI.

The required complete commands are:

```sh
bash Scripts/ci-macos.sh
bash Scripts/ci-apple-provider.sh
bash Scripts/ci-concurrency-seal.sh
bash Scripts/ci-linux.sh                       # hosted Linux runner
bash Scripts/ci-linux-reporting-repro.sh        # hosted five-attempt reproduction
```

The main scripts include audited authorization, RC5/per-call/run-record/image/
native/file reader compatibility and the new schema14 gate; they are not replaced
by selective suites. The issue's closing acceptance report links exact PR/main CI,
records local completion or failures, and distinguishes implementation, evidence
head and merge SHA/tree. CI uploads `.ci-logs`/metadata and bounded attempt output.
This prepared page does not assert that unfinished checks or main had already passed.

Three independent scoped reviews of the fixed implementation SHA/tree found no
unresolved P0/P1 or blocking P2: Core/Journal/mutation/storage; Provider encoding,
continuation and target support; runtime deadline/cancellation/drain, public API,
external client and docs. Reviewers read the final diff and actual targeted logs.
Complete CI is a separate requirement from these scoped review conclusions.

## Limits and follow-up

Missing durable terminal, unmatched tools, pending/quarantined mutation, persistent
trusted instructions, stale actors, owned queues and unsupported formats remain
local refusals. Drain is not reconciliation; Host must verify receipt/output and
use a fresh same-ID Session after reconciliation. Target adapters can still reject
an unsupported ordinary tail/view during preflight without retiring authority.

No paid live call or real-vendor signature verification was performed; constructed
signature strings and HTTP replay are not current model qualification. No automatic
summarization, current-Run native compaction with required reminders, arbitrary
current-tool excerpts or between-queued-reply maintenance was added. Those #105
limits remain. OtohaAI code/pins and the published RC6 tag/Release are unchanged.

Host follow-up: adopt a schema14 store or explicit offline upgrade; display advisory
control state; drain and reconcile uncertain effects; select a frozen target and
explicit omission/incomplete consent; await handoff/drain; send the next real input;
reconstruct the same target binding/scope on reopen and handle local refusals.
SDK acceptance does not constitute Host integration or product end-to-end acceptance.
