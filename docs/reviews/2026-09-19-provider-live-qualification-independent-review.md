# Provider Live Qualification Independent Review

last-verified: 2026-09-20

## Review identity

- Reviewer: Claude Fable 5.1 (`claude-fable-5-1`)
- Invocation: Herdr read-only agent in pane `w1A:p5`
- Repository: `OtohaPlayer/SwiftAgent`
- Baseline: `85ea79767f3782e3c98c339e3efc8bb150582680`
- Final reviewed code: `c17adeb86f5ea086e9ac9f2d454a41fbe7f85455`
- Scope: SAI-068 implementation, tests and the uncommitted documentation seal
- Network: no live Provider call was made by the reviewer

The reviewer inspected source and tests, exported committed code to a temporary
directory for fixture runs, checked every cited 40-character Git identity, and
reviewed the bounded live-evidence wording. It did not edit the repository.

## Findings and dispositions

| Finding | Severity | Codex disposition | Result |
| --- | --- | --- | --- |
| Documentation expanded the short `14c60ae` prefix into a non-existent 40-character identity | P2 | Accepted | Replaced every baseline pin with exact `git rev-parse` output; all cited identities resolve |
| Non-preflight fixture runs still parsed live endpoint configuration | P3 | Accepted | Fixture resolution now branches before live configuration parsing; deterministic regression added |
| Fixture preflight could expose live configuration | Previous P3 | Accepted and already remediated | Preflight reports `FIXTURE` / `UNUSED` and does not inspect live values |
| Persistent budget lock artifact was not ignored | Previous P3 | Accepted and already remediated | `*.live-budget.json.lock` is ignored |

Final focused review reported:

| P0 | P1 | P2 | P3 |
| --- | --- | --- | --- |
| 0 | 0 | 0 | 0 |

The reviewer also re-ran `ProviderQualification` (22 tests in five suites) and
`AppleChatApp` (21 tests in four suites), with zero failures or skips.

## Evidence boundary adjudication

The reviewer found the code and documentation seal internally consistent. Its
suggestion that SAI-068 could close after push is **partially accepted**: the
implementation and documentation findings are closed, but the task's explicit
acceptance rule requires agreed live evidence before `done`.

The following remain qualification gaps, not hidden passes:

- OpenAI and Anthropic durable tool-history restart live cases were not run
  because each Provider had only two sends left and the hardened case can need
  three.
- Official OpenAI was blocked by missing model configuration; gateway evidence
  does not qualify the official endpoint or encrypted reasoning continuation.
- DeepSeek exhausted its 12-send budget during remediation. Only a post-fix
  completed reasoning/usage response is qualified; post-fix text, tool,
  restart, structured and selected live event shapes remain unqualified.
- Apple PCC was unavailable on the test platform.
- iOS UI and a fresh AppleChatApp live visual inspection were not run.

Accordingly, this review closes its code/document findings but does not upgrade
the overall live qualification task or RC.2 release readiness.
