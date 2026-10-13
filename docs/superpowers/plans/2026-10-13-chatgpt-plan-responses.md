# #110 implementation and renewed RC6 seal

Approved design: [ChatGPT-plan contract](../specs/2026-10-13-chatgpt-plan-responses-design.md).

1. Retain compiling Swift RED for old request shape, plan SSE failures and plan
   catalog shape. Record exact baseline/working tree/toolchain/command/log.
2. Add bounded plan error mapping and a redacted per-dispatch token source.
   Add isolated request encoder, public Provider and catalog. Configure shared
   SSE validation narrowly for namespace/plan continuation/incomplete semantics;
   leave default API-key contracts intact.
3. GREEN request/stream/catalog tests; expand meaningful tests for namespace
   tampering, rotation, late-token cancellation, unsupported state, bounded
   errors, sanitized diagnostics and no premature success.
4. Add public-only ExternalClient temporary-Journal tool-loop/reopen fixture;
   existing complete CI already executes these tests. Verify one execution and
   unchanged canonical system instruction and execution facts.
5. Update public guide/versioning/CHANGELOG/RC6 acceptance. Run affected local
   Provider and public consumer tests, then applicable complete macOS gates.
   Linux and Apple gates execute independently in hosted CI.
6. Independent final-diff review in the original three acceptance directions;
   fix substantiated findings and rerun affected checks. Normal PR, checks and
   merge; actual new main commit/tree/CI review.
7. Recompute release target and documentation provenance. Repeat isolated public
   revision consumer, annotated tag checks (previous tags unchanged), actual
   tag checkout CI and cold exact-version public consumer; publish Pre-release
   only after all pass. Preserve old CI and superseded publication evidence.

No implementation step enables OAuth UI, refresh, native compaction, paid live
qualification, OtohaAI integration or further #105 maintenance.
