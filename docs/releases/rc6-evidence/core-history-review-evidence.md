Core history implementation evidence (macOS arm64, Apple Swift 6.4 swiftlang-6.4.0.34.1)

Commands and outcomes:
- First attempt: swift test --filter StaleJournalBaselineTests, PID 23630. Observed alive at 01:31 elapsed; first waited for runtime PID 23265, then stalled in planning with no compiler jobs. Agent explicitly terminated this own process with TERM; preserved stale-first-attempt.log. This is NOT RED test evidence.
- swift test --disable-sandbox --filter StaleJournalBaselineTests: stale-red.log, actual executed failure. Serial nextInput=three showed Provider [u1,a1,u3], Journal [u1,a1,u2,a3]. Same text=two was erroneously accepted as third Provider request rather than a distinct appended input. This log tests unmodified production Core.
- Same command after Core fix: stale-green.log, two default-schema3 cases PASS.
- Expanded suite: stale-green-expanded.log, four serial cases (schema3 and schema9 records x different/equal text) and normal witness path PASS.
- First final suite compilation: stale-green-final-compile-failure.log, unrelated provider worker's new test lacked try await on waitForDrain. No Core test executed; provider owner corrected its file.
- Bounded final rerun: stale-green-final.log, three tests / six cases PASS. Includes post-preflight startup publication conflict, zero transport, notAdmitted record; own checkpoints + noncheckpoint metadata + other Session + maintenance accepted. All serial stale cases preserve preexisting history, fresh actor continues, File Journal close/reopen exact.

Core ABI/schema: all new witness/snapshot APIs package-only; existing per-session historyHead, no schema or public initializer/enum/protocol change. Reconciliation doc comment and guide now require physical drain and fresh same-ID actor on same Journal handle, with no shared-handle close or original mutation replay.

Independent Provider review (reviewer core_history, not Provider implementer):
- Reviewed final AnthropicProvider.swift lines 149-167, 197-218: serialized Data is checked and then assigned unchanged as httpBody; transport starts only after check.
- Reviewed AnthropicContinuation.swift lines 49-91, encoder prefix capture/validation and decoder prefix recording: stable encoded system/tools/prior messages local digest witness, cache_control markers excluded; thinking/redacted_thinking with changed or absent witness is refused. No local cryptographic signature claim, no account/date inference, no automatic Run retry or canonical rewrite.
- Reviewed real Swift fixture outputs provider-boundary-green-final2.log: 34 tests / 8 suites PASS; 24MiB raw legal images -> 33,555,209 body bytes and zero transport; 20MiB plus long system/tools -> 33,962,859 and zero transport; exact 32,000,000 body dispatch accepted, 32,000,001 refused with transport count unchanged.
- Current primary docs checked: https://platform.claude.com/docs/en/api/errors lists Messages 32 MB; https://platform.claude.com/docs/zh-CN/build-with-claude/preserved-thinking states system/tools/prior messages binding and conditional model/account behavior. SDK's conservative local 32,000,000-byte guard and refusal policy are consistent. Fixture success is not live qualification.
- No blocking review finding. Known compatibility limitation: pre-RC6 signed-thinking continuations lacking the local prefix witness are refused rather than guessed; release docs must retain this restriction.

Issue #65 preexisting fix: e15996ab276f34d5a5904c1df13fe15b949090ba, tree 7074a2b990fc5b40ee60d2137333778da77dac58. LargeNoEffectBindingTests covers 250,014 canonical bytes and tampered digest/count; CompactNoEffectDiskTests covers archival version compatibility. Fresh complete gate, not this targeted A suite, must provide final execution evidence for closure.
