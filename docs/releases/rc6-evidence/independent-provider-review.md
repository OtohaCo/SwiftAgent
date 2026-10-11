# Independent Provider review seal

Reviewer: core_history (implemented Session/Journal, did not implement Provider changes).
Review source: c07678292f515fdeb46f77c13ff611d278430ef7 → 5ebbcb94be868a3d43578a1d0f97a11fb382b7b1.
Reviewed source tree: 81196a8e232d6c6c993f8404055e736ed01be7bb.
Result: PASS; no unresolved P0/P1 or release-blocking P2 findings.

The exact committed Provider/image-policy diff is identical to the reviewed implementation. Reviewed AnthropicProvider encodedRequest/stream, AnthropicRequestEncoder replay prefix capture, AnthropicContinuation digest validation, AnthropicStreamDecoder witness persistence, new request-boundary/thinking fixtures, image comments and Provider limitation guide. No production files edited during this independent review.

B: stream validates the final sorted-key JSON Data before invoking transport and assigns that exact Data to httpBody. Preflight validates through the same encoder. All body fields, base64, escaping, system, tools, history and output config count. Current official API errors page gives 32 MB without conversion; inclusive 32,000,000 bytes is an explicitly conservative local ceiling. Valid PNG fixture decode via ImageIO prevents earlier format failures masking size checks. Legal per-image/count raw combinations produce 33,555,209 bytes (24 MiB raw) and 33,962,859 bytes (20 MiB raw plus long text/tools), rejected with zero transport. Exact mixed body 32,000,000 dispatches once; 32,000,001 does not add a transport call.

C: policy B conservatively requires an unchanged locally witnessed system/tools/preceding-message prefix for native thinking/redacted_thinking, excluding cache_control as current official protocol permits. Fixed declarations with append-only continuation are accepted; deferred expansion, subsequent reset, prior result excerpt/summary and legacy missing-witness paths reject before transport. Executed tools and canonical history remain intact. The witness proves encoded-prefix correspondence only, not vendor signature or account qualification. No account-age inference, beta drop semantics, Run replay or paid live call was introduced.

Evidence reviewed: .ci-logs/rc6/provider-boundary-red.log (3 tests, 11 issues before fix); .ci-logs/rc6/provider-boundary-green-final2.log (34 tests / 8 suites PASS, actual Swift encoder and HTTP SSE fixtures). New tests were not rerun by reviewer because the full final gate is running. Root must bind that final gate/CI to this exact source before candidate acceptance.

Primary protocol sources independently checked: https://platform.claude.com/docs/en/api/errors and https://platform.claude.com/docs/zh-CN/build-with-claude/preserved-thinking. Fixture signatures are opaque test values, not live service qualification. Accepted local fixed-prefix paths do not establish a new real-model qualification. Pre-RC6 signed continuations lack the new witness and are intentionally refused; the support/compatibility guide documents this limitation and keeps canonical history intact.
