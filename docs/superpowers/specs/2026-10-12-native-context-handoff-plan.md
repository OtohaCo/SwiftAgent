# Issue #105 implementation and acceptance plan

Approved design: [native-context-handoff-design.md](2026-10-12-native-context-handoff-design.md).
No automatic summary, Host edits, paid calls or release publication.

1. **Storage prerequisite PR.** Add explicit opt-in schema 12 and exact old API
   overload compatibility. Implement offline schema-11 upgrade with a bounded
   FORMAT bridge and prepared identical-content root. New open verifies/recovers
   only the exact old→target CURRENT transition before ordinary writes. TDD covers
   supported creation, lock contention, data/identity preservation, old-reader
   refusal, every pre/post-gate fault point, forged/missing bridge/root refusal,
   and reopen/maintenance. Keep schema 3–11 unchanged by default.
2. **Authority handoff PR, depending on storage.** Add typed generation/parent-
   bound retirement state in the existing Session header/events and snapshots.
   Core builds a stable original-to-ordinary source mapping, omitting only
   explicitly authorized retired provider state. Preflight uses the target
   binding plus actual selected capability registry. Reuse maintenance operation
   reservation, deadline, cancellation, logical wait and physical drain. Publish
   unchanged canonical checkpoint and new epoch under history/native/control/
   completion/pending CAS; poison commitUnknown. Establish the target's fresh
   trusted control baseline; never revive an ancestor native chain. Validate
   source references against original persisted messages and apply the same
   frozen transformation to digests/views. Reject retired payload reinjection
   after projection. Run public File Journal model/tool-change, new thinking,
   next-Run/reopen, refusal and publication-fault/cancellation regressions.
3. **Queued controls in the runtime PR.** Preserve exact old initializer and add
   a required-new-label overload; freeze controls from the resolver and pass
   through `startQueuedFollowUp` to normal startup. Public two-reply HTTP fixture
   verifies reminders, one admission/execution, cancellation/drain/reopen. The
   resolver does not perform maintenance; dispatcher ownership is unchanged.
4. **Qualification and documentation.** Update guides/support/reader matrix and
   candidate materials with actual supported scope. Run repository full gates
   on final source, three independent final-diff reviews, PR CI and actual merged
   main CI. Keep first failed results and bounded diagnoses. #105 remains open
   for separately designed Run-internal and between-queued-replies maintenance.

An independent CI-diagnostics PR repairs false successful stack-capture labels
and validates real Linux ptrace before testing; it changes no SDK deadline,
assertion, coverage or watchdog budget. The current Linux build SIGSEGV and the
separate unattributed test watchdog remain documented until actual evidence
resolves them. A green different platform/run is not a substitute.
