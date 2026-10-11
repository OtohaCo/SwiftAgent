# RC6 focused evidence

Sanitized focused logs and independent review records. `<CHECKOUT>` replaces
local absolute paths. The manifest hashes original retained logs, not sanitized
copies. Source frozen for the complete gate: `5ebbcb94be868a3d43578a1d0f97a11fb382b7b1`,
tree `81196a8e232d6c6c993f8404055e736ed01be7bb`.

Local complete gates all exit 0: `bash Scripts/ci-macos.sh`,
`bash Scripts/ci-concurrency-seal.sh`, `bash Scripts/ci-apple-provider.sh`.
Full stage/source/process/exit evidence is retained locally under `.ci-logs/`;
hosted CI uploads its independent exact-checkout evidence. Focused logs do not
replace those complete gates or current-service live qualification.

The initial interrupted planning attempt and missing-try compilation failure
are retained locally and described in core-history-review-evidence.md. Old
`afterCurrentReplace` tests are not accepted as final-publication-after-deadline
proof; runtime-before-publication-deadline.log records the corrected test.
