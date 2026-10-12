# Native context Host fixture

Run `swift run --package-path Examples/ExternalClient NativeContextFixture`, or
`swift test --package-path Examples/ExternalClient --filter NativeContextPublicClientTests`.
Only public SDK APIs are imported. The transport returns local HTTP/SSE fixtures
in seven-byte fragments, including Chinese text split at UTF-8 boundaries. No
credentials, sockets or paid live calls are used. Fixture signatures and ciphertext
do not prove vendor cryptographic or account qualification.

`NativeContextHostExample` demonstrates two flows:

1. Anthropic: explicitly qualify on-demand/inline-tools/reminder support for an
   endpoint and resolved model. Bind trusted discover/extra executors. Drain the
   previous Run, idle compact and commit, then admit a real new user with
   `AgentRunContextControls(reminder: "本轮请用中文回答")`. A signed-thinking tool
   proposal executes discovery once; the next model request appends the newly
   declared deferred tool and reasserts the reminder after the complete tool-result
   boundary. The root and existing thinking remain unchanged. Close/reopen and a
   fresh capability binding restore the correct state; the next Run resets deferred
   declarations through an append-only removal. Covered text remains in canonical
   history. An unqualified proxy returns a local unsupported-capability error.
2. OpenAI: use a frozen service-scoped catalog statement to select automatic mode,
   then explicitly configure a Host trigger and endpoint qualification. Metadata
   alone grants no capability. An actual response contains a complete compaction
   item followed by a function call within the same assistant response. Core
   publishes the accepted checkpoint/tool facts atomically; the next same-Run HTTP
   uses the compacted window and actual tool output. Next Run and FileStore reopen
   retain the native window without repeating the tool or the covered full source.
   Compaction progress/usage remain diagnostics, not answers.

The test is one test containing both flows. It checks actual request bodies,
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

Threshold compaction plus required reminder, compaction over a live reminder or
permanent mid-conversation instructions, arbitrary thinking-tail cuts, historical
controls in managed thinking-tail compaction, and unqualified deployments are
explicitly unsupported. A failed controlled request without an accepted assistant
cannot be followed by an illegal system→user wire history; SDK fails before new
admission. It does not synthesize an assistant, replay mutations or retry the Run.
