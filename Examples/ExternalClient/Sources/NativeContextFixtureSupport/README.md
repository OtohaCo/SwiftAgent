# Native context Host fixture

Run `swift run --package-path Examples/ExternalClient NativeContextFixture`, or
`swift test --package-path Examples/ExternalClient --filter NativeContextPublicClientTests`.
Only public SDK APIs are imported. The transport returns local HTTP/SSE fixtures
in seven-byte fragments, including Chinese text split at UTF-8 boundaries. No
credentials, sockets or paid live calls are used. Fixture signatures and ciphertext
do not prove vendor cryptographic or account qualification.

`NativeContextHostExample` demonstrates three flows:

1. Anthropic serviceDefault (omits thinking): explicitly qualify on-demand/inline-tools/reminder support for an
   endpoint and resolved Sonnet 5.5 model. Bind trusted discover/extra executors.
   The previous Run uses its own reminder and a signed-thinking tool loop,
   completes successfully and drains. Idle whole-history compact commits a signed
   checkpoint covering its reminder and trusted native tool changes. Then admit a real new user with
   `AgentRunContextControls(reminder: "本轮请用中文回答")`. A signed-thinking tool
   proposal executes discovery once per Run (two total); the next model request appends the newly
   declared deferred tool and reasserts the reminder after the complete tool-result
   boundary. The root and existing thinking remain unchanged. Close/reopen and a
   fresh capability binding restore the correct state; the next Run resets deferred
   declarations through an append-only removal. Covered text remains in canonical
   history. An unqualified proxy returns a local unsupported-capability error.
2. Anthropic betweenTools: repeats the same flow with exactly
   `thinking:{type:"between_tools"}`. Signed progress thinking is retained and
   replayed unchanged. No extra thinking beta or mismatch qualification is used.
3. OpenAI: use a frozen service-scoped catalog statement to select automatic mode,
   then explicitly configure a Host trigger and endpoint qualification. Metadata
   alone grants no capability. An actual response contains a complete compaction
   item followed by a function call within the same assistant response. Core
   publishes the accepted checkpoint/tool facts atomically; the next same-Run HTTP
   uses the compacted window and actual tool output. Next Run and FileStore reopen
   retain the native window without repeating the tool or the covered full source.
   Compaction progress/usage remain diagnostics, not answers.

The test is one test containing all three flows. It checks actual request bodies,
canonical history, native state recovery and execution counts. The separate
DynamicModelRouting public fixture demonstrates exact sub2api price-tier mapping,
per-sampling model/price selection, service isolation and honest unknown costs.

A `supportsNativeContext: true` File Journal explicitly opts into schema 11; the
existing default remains schema 3. Do not open a schema-11 store with older readers.
Use the same explicit deployment/root binding after reopen. Fixed continuation
binding revision can be separated from Host profile metadata revision when only
trusted append-only executor declarations change. Genuine model, root, endpoint,
dialect or configuration changes require a separately authorized handoff, not
silent opaque-state reuse.

Threshold compaction plus required reminder, Run-local compaction over a current required reminder or
permanent mid-conversation instructions, arbitrary thinking-tail cuts, historical
controls in managed thinking-tail compaction, and unqualified deployments are
explicitly unsupported. A failed controlled request without an accepted assistant
cannot be followed by an illegal system→user wire history; SDK fails before new
admission. It does not synthesize an assistant, replay mutations or retry the Run.

Idle whole-history on-demand is the narrow completed-reminder exception, not an
expiry of clear_at. File Journal proves the completed Run, admission, history head
and empty pending state at qualification and again inside publication. Repeated
compaction/reopen uses that same contract. Unknown or failed prior terminals stay
refused. Threshold/reminder is a currently unimplemented SDK scheduling combination,
not a universal vendor restriction. Fixture success is not live qualification.

## Explicit handoff and queued reminder fixtures (#105)

`ordinaryHandoff()` uses opt-in schema 12, completed/drained idle compaction,
explicit native/control retirement, an original-source-bound deterministic
summary, a new target binding and a new generation-1 native chain; reopen
retains the correct chain and unchanged canonical prefix.
`thinkingAcrossOrdinaryHandoff()` (see the public test entry point) checks target thinking,
changed registry and rejection of a reencoded retired continuation.
`queuedReminders()` uses the public resolver overload for two tool-loop replies
with different reminders, exact executor/admission counts and File Journal
reopen; its cancellation variant blocks preflight and sends zero HTTP requests.
These are HTTP fixtures, not live or cryptographic qualification.
See [Host handoff guide](../../../../docs/guides/swift-agent-context-handoff.md)
for offline schema-11 upgrade and failure/drain contracts. Long tool-loop and
between-queued-replies maintenance are not implemented.

## Incomplete-turn handoff (#108, after RC6)

`incompleteOrdinaryHandoff()` uses only public SDK APIs and real Anthropic Swift
HTTP encoding with local fragmented SSE. It preserves signed canonical history
and a max-tokens terminal, upgrades the closed schema-12 store to schema 14,
explicitly retires authority without HTTP/tool execution, then runs a new target
with a changed registry and normal deferred expansion. Discovery executes once;
reopen retains history/terminal and does not replay it. Fixtures are neither
vendor signature verification nor current model/account qualification.

Schema 14 factories and explicit 12/13 upgrade are required for incomplete exit.
Old completed-only handoff and idle compaction restrictions above remain applicable
to their original APIs. No Run-local compaction or queued maintenance is enabled.
