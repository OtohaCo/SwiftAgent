# Independent review: Session / Journal admission and recovery

Reviewer: runtime_context agent (did not implement history witness changes).
Reviewed final working-tree diff of AgentSession.swift, AgentJournal.swift,
StaleJournalBaselineTests.swift and underlying SegmentedJournalStore read/write,
commit historyHead and maintenance behavior. Parent final candidate commit and
CI identity must be attached after commit.

Result: no blocking findings.

- historySnapshot captures checkpoint/historyHead from one store.read root.
- startRun compares actor persistent baseline before preflight; live
  conversationRevision is not used as persistent version.
- appendStartupCheckpoint passes expectedHistory into store.write closure;
  file append rejects before Run admission records/message publication.
- Stale pre-admission rejection releases startup reservation, never refreshes
  witness as though stale actor had restored history.
- Actual admitted Runs refresh witness only after committed-write retention,
  logical completion and physical loop drain, before lease/identity release.
- Per-session historyHead advances for checkpoint publications; other Session,
  metadata/audit-only commits and physical maintenance preserve it.
- Tests exercise serial default schema 3, identical input text, Run records,
  fresh continuation, reopen, unrelated commits and post-preflight publication.
- Definite/unknown final checkpoint failures remain errors in independent
  AgentSettledAnswerDeadlineTests; final deadline/cancel publication paths pass.

Evidence observed: stale-red.log and expanded stale-green.log (worker reports);
final publication race run initially blocked by unrelated new provider-test
compilation error, attributed and notified rather than marked passed. Final
successful rerun and complete gate belong to parent candidate acceptance.
