# SwiftAgent 1.0 RC Audit

> Audit date: 2026-09-18
> Requested review artifact: `2026-09-19-swift-agent-1.0-rc-audit.md`
> Baseline: `3e47373eedf89c50d9642f11d0268d00f9e5ea91` on `plan/swift-agent-engine`
> Status: Complete

This review treats SwiftAgent as an independent third-party SDK. Findings are
classified before production changes. Only P0, P1, and P2 RC blockers may
change runtime semantics during SAI-047.

## Finding register

| Area | Contract | Current state | Evidence | Finding | Severity | RC blocker | Action | Result |
|---|---|---|---|---|---|---|---|---|
| Journal migration | Every valid v1/v2/v3 journal remains readable or fails closed without replay | v3 originally rejected a v2-valid duplicate identity across Sessions | `testValidV2SessionScopedDuplicateIdentitiesRemainLoadableAndFailClosed` | Confirmed compatibility defect | P1 | Yes | Accept legacy collisions only during rebuild; select the most conservative state for admission | Fixed |
| Journal compaction | A loaded legacy journal can be compacted without changing mutation meaning | Canonical rewrite originally relabelled retained v1 records as v3 | `testLegacyV1PendingMutationSurvivesCompactionAndRestart` | Confirmed compatibility defect | P2 RC blocker | Yes | Preserve retained record schema while new records remain v3 | Fixed |
| Journal repair | A corrupt terminal frame preserves the valid prefix and can be explicitly discarded | A non-zero oversized terminal length originally threw before repair | `testTerminalInvalidLengthWithNonzeroPayloadIsRepairableCorruptTail` | Confirmed repair gap | P2 RC blocker | Yes | Classify an impossible incomplete oversized terminal frame as `corruptTail`; keep parseable middle corruption fail-closed | Fixed |
| Mutation indexes | Admission and recovery work should scale with one identity or Session lifecycle, not all historical mutations | Rebuilding initially rescanned every mutation for both identity precedence and same-Session unresolved admission | `AgentJournal.refreshIdentityIndex`, `unresolvedMutationBySession`, mutation recovery and idempotency suites | Accidental O(N^2) journal rebuild path | P2 RC blocker | Yes | Maintain an identity-to-member bucket plus one unresolved mutation key per Session | Fixed |
| Receipt/cancel drain | Session identity release must wait for terminal cleanup as well as executor/provider drain | Parallel full-suite execution reproduced `.intent` after `waitForRunToDrain()`, followed by a stale-writer rejection on reload | `AgentRunControl.waitUntilCompleted`, `AgentSession.finish`, `testReceiptAndCancellationDoNotDoubleSettle` | Confirmed production race: executor drain could complete before cancellation quarantine and logical terminal cleanup | P2 RC blocker | Yes | Make Session-owned drain await both logical completion and physical provider/tool drain; make the test wait for actual executor entry | Fixed |
| Session lease test | Lease release is a physical-drain invariant | Test asserted lease release after `wait()` instead of `waitForDrain()` | `testSessionAcquiresAndReleasesDurableLease`, parallel full suite | Parallel run intermittently observed the still-owned lease | P2 test contract | Yes for trustworthy RC validation | Await `run.waitForDrain()` before replacement ownership | Fixed |
| Apple concurrency tests | Supported Apple CI should execute resource and completion cancellation races | Test-only `Task.immediate` availability skipped nine tests on macOS 15 | `ToolResourceCoordinatorTests`, `AgentCompletionCommitTests` | Coverage defect | P2 RC blocker | Yes | Replace availability-gated scheduling with deterministic actor handshakes | Fixed |
| Provider route capability | Public capabilities must describe observable delivery | Route validates the complete candidate before publishing | `routeDoesNotAdvertiseStreamingWhenItBuffersCandidateResponses` | `.streaming` was misleading | P2 RC blocker | Yes | Remove `.streaming` from the route capability intersection | Fixed |
| Provider route namespace | Route construction must reject unusable candidates | Requests are forwarded unchanged | `routeRejectsCandidateFromAnotherProviderNamespace` | Mixed descriptor IDs constructed but could not serve the request | P2 RC blocker | Yes | Reject candidate IDs that differ from the route ID | Fixed |
| Provider retry | Classified retry hints must be honored | Same-provider retry originally ignored `retryAfter` | retry delay and cancellation tests | Retry could amplify throttling | P2 RC blocker | Yes | Use cancellation-aware delay before the retry | Fixed |
| Event buffering | Run events must not affect run correctness when an observer exits | Run and loop streams use unbounded buffering | `AgentSession`, `AgentLoop`, events guide | A retained undrained Run can grow memory until its bounded run terminates | P3 | No | Keep documented single-consumer/drain obligation; consider bounded diagnostics post-RC | Open |
| Tombstone retention | Idempotency safety survives restart and compaction | Terminal identities are retained indefinitely and indexed | `AgentJournal.canonicalRecoveryRecords`, SAI-046 | Canonical journal size grows with unique terminal identities | P2 post-RC | No | Keep correctness-first retention; SAI-046 owns an explicit future policy | Open |
| External consumer | The sample must prove only public API is needed for core workflows | ExternalClient now executes read-only, mutation, restart, idempotent replay, recoverable error, wait, and drain paths | `ExternalClientTests` | Coverage gap | P2 RC blocker | Yes | Add a real model-visible recoverable failure loop without internal imports | Fixed |
| Documentation links | Independent repository documentation must have valid relative links | Tools guide linked to a missing plans document | local Markdown link scan | Fresh-reader navigation was broken | P2 RC blocker | Yes | Link to the permanent conformance evidence | Fixed |
| Linux warnings | SwiftAgent must compile on the declared Linux toolchain without unexplained package warnings | Linux exposed an unavailable test-only Sendable conformance and a deprecated URL error key | `ProviderHTTPTransportTests`, final `Scripts/ci-linux.sh` log | Test fixture portability defect | P2 RC blocker | Yes | Gate the Darwin-only conformance and use the URL-typed key | Fixed |
| Public API inventory | Every public member needs an explicit 1.0 disposition, not only its containing type | The prior review summarized top-level types but did not enumerate every member | `2026-09-19-swift-agent-public-api-members.md`, generated symbol graphs | Member-level audit evidence gap | P2 RC blocker | Yes | Inventory all 956 symbols with module, kind, source location, precise identifier, and disposition | Fixed |
| Tingting host seal | The embedded SDK must not leave its current product host red or hung | SAI-048 repaired stale source contracts and isolated AppKit/SwiftUI window fixtures from persisted drawer state and host Keychain access | `DrawerChromeTests`, `FirstRunGuideExperienceTests`, final `Tingting SK` full-suite log | Host release seal is green; no SwiftAgent production source changed | P2 RC blocker | Yes | Keep window tests deterministic and fail closed in the XCTest license host | Fixed |
| Hosted CI | A published RC needs independent macOS/Linux CI outside the Tingting checkout | `SwiftAgent CI` executes explicit macOS 27/Swift 6.4, Ubuntu 24.04/Swift 6.4, and Apple adapter jobs with metadata, timeouts, ExternalClient coverage, and a fail-closed 11-test plus 3-test concurrency seal | SAI-041; `OtohaPlayer/SwiftAgent` run `35410345928`; all three jobs used non-zero runner IDs and completed successfully | The final repository supplies independent hosted evidence without relying on the blocked Tingting account | P2 RC blocker | Yes | Preserve the workflow and audit counts/skips before each RC tag | Fixed |
| Repository release preparation | An RC needs a canonical repository URL, confirmed license imprint, valid install links, changelog, and tag workflow | `OtohaPlayer/SwiftAgent` is extracted with history; README, MIT license, changelog, release notes, provenance, clean-clone validation, and CI are complete | `docs/extraction.md`, `docs/releases/1.0-rc-checklist.md`, clean remote clone and install smoke | Release preparation is complete; tag and GitHub Release remain intentionally authorization-gated | P2 RC blocker | Yes | Await explicit authorization before creating `1.0.0-rc.1` | Fixed |
| Workspace adapter | Optional host adapters must not become Core dependencies | `WorkspaceAgent` is a separate product depending on Core, Providers, Tools, Models, and Crypto | `Package.swift`, architecture tests | No dependency inversion; its API is optional/reference-host surface | Not an issue | No | Classify as optional/experimental adapter in release docs | Accepted |
| Swift tools version | Declared compiler contract must match tested behavior | Manifest uses tools version 6.0 and Swift language mode 6; validation uses Swift 6.4 | `Package.swift`, CI scripts | Tools version is the manifest syntax floor, not a claim of full 6.0 validation | Not an issue | No | Document Swift 6.4 as the validated compiler | Accepted |
| Synthetic summary | Compaction summaries must not masquerade as semantic user input | Internal wire representation is a `.user` message with one internal prefix | `AgentContextWindow`, context tests | Implementation is portable but third parties must not parse the prefix | P3 | No | Freeze as a private 1.0 implementation detail | Accepted |
| Schema envelope validation | Frame and record versions should agree with their historical vocabulary | Reader accepts supported frame and record versions independently | `AgentJournal.read` | Mixed-version envelopes are accepted if records decode and validate | P3 | No | Consider stricter fixtures and version-vocabulary validation post-RC | Open |
| Frozen historical fixtures | Backward compatibility should be proven against bytes produced by released historical encoders | Current v1/v2 regressions construct legacy-shaped records with the current test encoder | `AgentJournalTests`, SAI-050 | No checked-in golden v1/v2 journal byte fixtures | P3 | No | Add provenance-recorded immutable v1/v2 fixtures without changing current compatibility semantics | Open |
| Test wait observers | Test-only exact-count observers should not leak when abandoned | Resource coordinator package hook stores non-cancellable observers | `ToolResourceCoordinator.waitUntilPendingWaiterCountEquals` | Abandoned test observers can remain until coordinator release | P3 | No | Replace with tokenized test instrumentation post-RC | Open |

Finding totals: P0 0; P1 1 fixed / 0 open; P2 RC blocker 17 fixed / 0
open; P2 post-RC 1; P3 5; Not an issue 2.

## Package boundary

The Core product graph is acyclic and points inward:

- `AgentModels` has no SwiftAgent dependency.
- `AgentTools` depends on `AgentModels`.
- `AgentProviders` depends on `AgentModels`.
- `AgentCore` depends on `AgentModels` and `AgentTools`.
- `AgentAppleProvider` is a separate optional product.
- `WorkspaceAgent` is a separate optional reference-host product.

No Core production source imports Tingting, Otoha, UI, Workspace, or Apple
provider implementations.

Generated symbol graphs report 956 public symbols and 100 public top-level
types. Every initializer, method, property, subscript, case, and type is listed
with a precise identifier and source location in the
[member inventory](2026-09-19-swift-agent-public-api-members.md). The top-level
type split is AgentModels 26,
AgentTools 26, AgentCore 32, AgentProviders 8, AgentAppleProvider 1, and
WorkspaceAgent 7. Classification: KEEP 100, NARROW 0, REMOVE 0. The Workspace
types remain optional Reference Host API, not Core compatibility surface.
Member-level classification: KEEP 956, NARROW 0, REMOVE 0.

## Frozen contract decisions

- Keep the validated, throwing `RecoverableToolError` initializer. The unusual
  `throw try RecoverableToolError(...)` spelling makes invalid public payloads
  a typed construction error instead of a precondition crash or normalization.
- Freeze `AgentRun.wait()` as logical termination and throwing
  `AgentRun.waitForDrain()` as cancellable observer wait for physical drain.
  Cancelling one drain waiter never cancels the Session-owned drain.
- Keep synthetic conversation summaries as an internal wire representation.
  They are not semantic user input, Evidence, or public parsing surface.
- Keep indefinite mutation tombstone retention for 1.0. Journal size is bounded
  relative to canonical recovery/idempotency state, not absolutely bounded.
- `nil` operation ID does not provide cross-Run host retry deduplication.
- `ModelProviderRoute` only composes candidates with the same provider
  namespace. It buffers until terminal validation and therefore does not claim
  realtime streaming. Same-provider retries honor `retryAfter`.

## Runtime and compatibility seal

| Area | Frozen result | Evidence |
| --- | --- | --- |
| Terminal lifecycle | `runStarted`, one terminal result, one `runFinished`, one event-stream finish | `AgentEventContractTests`, `AgentRunTests`, failure and recovery suites |
| Cancellation and drain | `wait()` is logical; `waitForDrain()` is physical and waiter-cancellable without cancelling owned drain | `AgentRunTests`, `AgentSessionHangTests`, `AgentIsolationTests` |
| Conversation and compaction | Committed tool transcripts cross Runs/restarts; no compactor fails closed; mid-Run canonical history is reused | conversation/context policy suites |
| Provider continuation | Opaque, provider-specific, not conversation memory; incomplete or foreign continuation is discarded | continuation and fallback suites |
| Recoverable errors | Only opted-in read-only `RecoverableToolError` becomes `isError`; safety and mutation failures stay fatal | `AgentRecoverableToolErrorTests`, ExternalClient |
| Evidence | Transcript, summary, and recoverable error payloads cannot mint Evidence; Evidence is not reconstructed after restart | Evidence and conversation suites |
| Mutation and idempotency | Intent precedes executor; uncertain states never replay; settled replay reuses durable output/receipt within one journal domain | mutation recovery/idempotency/fallback suites |
| Journal | v3 writes; v1/v2/v3 read; explicit corrupt-tail repair; atomic compact; stale writers fail closed | `AgentJournalTests` (24 tests) |
| Apple boundary | Core minimum remains macOS 13/iOS 16; Foundation Models implementation is an optional target gated at macOS/iOS 26 | `Package.swift`, Apple provider guide and compile tests |

`ModelMessage`, including Unicode and `ToolResultMessage.isError`, retains its
Codable round-trip. ToolPolicy payloads written before `recoverableErrors`
decode to `.failClosed`. Public error cases remain typed; callers must account
for enum expansion before the 1.0 freeze.

## Concurrency review

- `AgentRunControl` and `AgentRunDrain` keep waiter continuations actor-isolated,
  remove cancelled waiters by identity, and resume each waiter once.
- Session drain identity is released only after `AgentRunControl` reaches its
  logical terminal result and `AgentLoop` reports provider/tool physical drain.
  This closes the reproduced window where restart could observe `.intent`
  before cancellation quarantine was durable.
- `AgentEventEmitter` serializes terminal publication and reserved tool
  completions; the package-only finishing handshake replaces availability-
  gated test scheduling without changing public behavior.
- `ToolResourceCoordinator` owns leases and waiters in one actor. Cancellation
  removes only a queued waiter; a lease returned concurrently is explicitly
  released before cancellation escapes.
- The two production `@unchecked Sendable` classes are lock-backed boundary
  objects: `ProviderHTTPSessionDelegate` detaches URLSession lifecycle state
  under one lock, and `AgentJournalStorageBox` protects its value with one lock.
  No `nonisolated(unsafe)` production declaration exists.
- `run.events` remains a single-consumer, unbounded stream for one bounded Run.
  Observer cancellation does not cancel execution. Long-lived undrained event
  retention is the recorded P3, not a terminal correctness dependency.

## Backlog judgment

- SAI-041 is complete. The independent repository provides the required hosted
  macOS, Linux, Apple adapter, ExternalClient, and concurrency evidence.
- SAI-045 is not an RC blocker; Hosts can await the active Run and start the
  next user turn explicitly.
- SAI-046 is not an RC blocker; indefinite retention is the conservative safety
  default and admission uses an identity index rather than a linear scan.
- SAI-050 is not an RC blocker; current migration regressions cover the accepted
  v1/v2 vocabulary, while immutable bytes from historical encoders would make
  that evidence stronger without changing runtime semantics.

## Validation record

- The original parallel full suite reproduced the receipt/cancel race once:
  journal state remained `.intent`, no quarantine record existed, and reload
  then failed closed as a stale writer. After the drain fix, isolated-process
  receipt/cancel stress passed 100/100 and the parallel full suite passed.
- Selected cancellation, drain, ordering, and isolation suites: 100
  repetitions, 0 failures across 17 Swift Testing cases.
- Public symbol graphs generated for all six products with
  `swift package dump-symbol-graph`; 100 public top-level types were reviewed.
- Journal regressions: 24/24 passed after the fix.
- Provider fallback regressions: 13/13 passed after the fix.
- Resource coordinator regressions: 11/11 passed on the current Apple runtime
  without availability skips.
- Swift 6.4 macOS no-parallel and parallel package suites both passed: 124
  XCTest cases plus 340 Swift Testing cases. Three operator-only live-provider
  tests were skipped; no Core test was skipped.
- Ubuntu 24.04 / Swift 6.4.2-dev `Scripts/ci-linux.sh` passed. Core target
  isolation passed, 124 XCTest cases and 334 Swift Testing cases passed, and
  final logs contain no SwiftAgent warning.
- Independent hosted run `35410345928` passed on macOS 27.0 / Xcode 27.0 /
  Apple Swift 6.4 and Ubuntu 24.04.5 / Swift 6.4. macOS passed 124 XCTest cases
  and 340 Swift Testing cases with only three documented live-provider skips;
  Linux passed 124 XCTest cases and 334 Swift Testing cases with only the
  Anthropic real-cloud skip. ExternalClient passed 6/6 on both platforms. The
  explicit macOS concurrency seal passed `ToolResourceCoordinatorTests` 11/11
  and `AgentCompletionCommitTests` 3/3 without skips. The Apple adapter job
  passed 14 fixture/unit tests with its two live-model tests skipped by policy.
- ExternalClient: 6/6 passed on macOS and Linux using public API only.
- Otoha focused seal: 4/4 passed. iOS Simulator `Tingting-iOS` build passed.
- SAI-048 macOS `Tingting SK` host seal passed: 2850 tests executed, 22
  documented skips, 0 failures, and normal process exit in 70.947 seconds.
  The original Preferences runtime regression now completes in 0.25 seconds
  under the same 30-second external guard.
- Local Markdown links pass. SwiftAgent production sources contain no Tingting
  or Otoha dependency. The MIT license is confirmed as
  `Copyright (c) 2026 ChainBow Co., Ltd.`. A clean remote clone passed macOS,
  Linux, Apple adapter, ExternalClient, concurrency, and authenticated HTTPS
  SwiftPM installation validation.

## Verdict

`READY FOR 1.0.0-rc.1`.

SwiftAgent has zero open P0, P1, or P2 RC blockers. SAI-045, SAI-046, and
SAI-050 remain post-RC work and do not weaken current correctness contracts.
Creating the tag and GitHub Release requires explicit release authorization.
