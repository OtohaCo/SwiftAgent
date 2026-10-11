# Independent runtime/context/release review

Reviewer: provider_boundaries agent (did not implement runtime/context files).
Scope: AgentRun comments, AgentSettledAnswerDeadlineTests, external ContextPipelineFixture, Host/context/versioning/release notes and candidate acceptance.

Evidence inspected: runtime-final-checkpoint-and-faults.log (6 tests, including 4 final-publication cases and 2 faults); context-host-fixture.log (public executable, successful close/reopen and cancellation); source diff and AgentLoop final-response/checkpoint gates.

Finding P2 (publication acceptance): finalCheckpointPublicationCrossesDeadlineAndReopensExactlyOnce initially uses PublishedCheckpointHold with .afterCurrentReplace. That proves the return crosses deadline, not actual CURRENT publication after deadline. The user specifically requires durable final publication crossing deadline. Requested configurable hold stage .beforeCurrentReplace/.beforeAppend and repeat actual deadline/reopen test; keep old post-publication helper default for existing cancellation regressions. Status: sent to runtime worker; pending amended source/results.

No other blocking findings from inspected changes. External fixture uses public imports only; source-referencing wrapper forwards immutable span requirements; fixed object yields per-request views and validates number of calls. Canonical state retains full tool result and current input; cancellation prevents a late request while physical work drains. Reopen equality covers both completed and cancelled histories. Host guide accurately limits Composite prepared summaries/excerpts to eligible old closed groups, distinguishes correspondence from semantic summary correctness, and defers arbitrary current-tool transformations/durable effect provenance.

AgentRun cancellation/deadline comments match the logical finishing seal before final checkpoint and the existing gate reopen on steering. Definite final commit failure and commitUnknown continue surfacing real errors. The release materials remain prepared/pending and make no tag, Release, Host integration or new live qualification claim. Compatibility guide correctly separates this closeout's no API/schema addition from earlier RC5→RC6 prerelease source breaks and identifies old signed continuations without prefix witness as intentionally locally rejected.

P2 resolved and independently rechecked: helper now accepts selected stage with unchanged .afterCurrentReplace default, while new #97 test selects .beforeCurrentReplace. Provider checks published startup user-only checkpoint, captures CURRENT bytes, test asserts barrier entered before deadline and published CURRENT remains identical after deadline. Release permits actual final root publication only after deadline; final result, drain and reopen/Run records checked. runtime-before-publication-deadline.log: 6 tests passed (4 records/cancel publication combinations, 2 persistence fault cases plus no-answer/steering/late-read gates). No unresolved findings in this review scope.

## Exact-source seal

Final reviewed source: 5ebbcb94be868a3d43578a1d0f97a11fb382b7b1.
Tree: 81196a8e232d6c6c993f8404055e736ed01be7bb.
PR: https://github.com/OtohaCo/SwiftAgent/pull/98.
Comparison baseline: c07678292f515fdeb46f77c13ff611d278430ef7.

Reviewed committed final diff in runtime/context scope and final release/acceptance/Host guide content. Corrected actual-before-publication result runtime-before-publication-deadline.log retained: 6 tests green; 4 records/cancel combinations and 2 final persistence fault cases. No new builds were run during complete gate ownership. P2 above resolved. No unresolved P0/P1 or release-blocking P2 in this review scope. This is source plus targeted-result review, not a substitute for pending exact-head full CI or actual-main acceptance.
