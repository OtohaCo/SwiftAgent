# Issue #108 implementation and acceptance plan

Design approved by user on 2026-10-14. Isolated branch:
`feat/incomplete-native-handoff`; immutable baseline: main
`a7940ae0286c7accef4aef8647919c57c042b8b9`.

1. Preserve a real Swift File Journal runtime RED for the existing completed-only
   refusal. Record compiler/platform and distinguish compile failures from RED.
2. Add validated closed-turn proof and target model/registry evidence, preserving
   existing completedRunID semantics and exact old handoff signature. Add the
   read-only Journal control API. Recheck proof in publication and target evidence
   on subsequent requests/reopen. GREEN the first slice using opt-in schema 14.
3. Add named schema 14 creation factories and writer-exclusive schema 12/13 upgrade,
   using the existing reader-gate bridge. Exercise both source schemas, controlled
   failures, real child-process crashes, recovery refusal and file preservation.
4. Extend public operation tests for user/assistant/tool tails, cancellation,
   admission error, pending/reconciliation, stale state, missing proof, target
   mismatches and metadata races. Keep original completed-path coverage intact.
5. Add real Anthropic Swift HTTP fixtures and exported-API external Host fixture;
   verify no synthetic dispatch/admission/tool replay and exact reopen history.
6. Add actual RC6 reader rejection and old API function-reference compatibility
   to applicable CI scripts. Update handoff/recovery/versioning/API/CHANGELOG.
7. Run affected suites then full applicable macOS/Apple/iOS/external/compatibility
   gates. Independently review storage/mutation, Provider, runtime/API/docs final
   diff and actual results. Resolve findings and rerun affected checks.
8. Commit, push PR and verify exact-head hosted CI. Merge through PR when approved
   checks/reviews pass; verify actual main and its CI. Record SHA/tree, original
   failures, retries and limits. No tag/Release or OtohaAI changes.

Evidence belongs in `.ci-logs/issue108` and source-bound CI stage directories;
stable acceptance documentation identifies the tested source, not just doc head.
