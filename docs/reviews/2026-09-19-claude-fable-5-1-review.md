# Claude Fable 5.1 Independent Review

> last-verified: 2026-09-19

## Metadata

- Repository: `OtohaPlayer/SwiftAgent`
- Reviewed SHA: `d2347f11c6a78f421708e897dae42a51a98d37ea`
- Model: Claude Fable 5.1
- Invocation: Herdr workspace Panel 2, read-only full-repository review
- Prompt: [claude-fable-5-1-review.md](prompts/claude-fable-5-1-review.md)
- Reviewer result: P0 0, P1 1, P2 2, P3 3, architecture suggestions 2

The findings below preserve the review substance. The Codex disposition is a
separate decision based on the frozen contracts, source, tests, and release
audit.

## Findings and Disposition

### P1: Parent directory was not synced for a newly published journal

**Reviewer evidence:** `Sources/AgentCore/AgentJournal.swift` created a new
journal and synced the file descriptor, but only the compaction path synced the
parent directory. `persist(to:)` also published a temporary file by move or
replace without syncing the directory.

**Impact:** a successful durable intent append could precede an externally
executed mutation even though the new directory entry was not crash-durable.

**Disposition: Accepted.** This violates the durable-intent contract. SAI-059
adds parent-directory sync after first-file creation and snapshot publication.
If the frame was already published before directory sync fails, the actor adopts
that conservative on-disk state before returning a typed persistence failure;
it cannot continue from an older snapshot or execute the mutation. A failed
memory-journal snapshot publication does not advertise the journal as durable.

### P2: Anthropic response model identity was silently relabelled

**Reviewer evidence:** `AnthropicStreamDecoder` only required a non-empty native
`message.model`, then constructed `ResponseInfo` with the requested model. This
made AgentCore's model-mismatch guard ineffective for this adapter.

**Disposition: Accepted.** SAI-059 requires the native model name to equal the
requested `ModelID.name` by default. Hosts using an older Anthropic convenience
alias can explicitly provide its expected resolved model ID; any other response
remains invalid. SwiftAgent does not infer alias equivalence or silently accept
an arbitrary provider identity.

### P2: Journal append and retained identity cost grows with history

**Reviewer evidence:** durable append reads and validates the complete journal
to detect stale writers. Canonical recovery retains mutation lifecycle state and
terminal identities indefinitely.

**Disposition: Partially accepted, post-RC.** The scaling concern is real. The
terminal identity retention is also the deliberate correctness-first SAI-046
contract: removing a tombstone can permit an old logical mutation to execute
again. The rc.1 audit already classified finite retention as post-RC. A future
design must address append validation and retention together; it is not changed
as a side effect of provider work.

### P3: Run and provider event streams use unbounded buffering

**Disposition: Accepted as P3.** The rc.1 audit already records this bounded-run
memory risk. A buffering policy must define loss rules for terminal and tool
lifecycle events before the public stream contract can change.

### P3: Frame and record schema versions can differ

**Disposition: Accepted as P3.** The reader deliberately accepts supported
legacy record versions while loading and compacting historical journals. Future
version-vocabulary validation must be based on immutable historical fixtures so
it does not reject accepted v1/v2 data.

### P3: v1/v2 tests do not contain historical byte fixtures

**Disposition: Accepted as P3.** SAI-050 owns immutable byte fixtures with
provenance. Current tests prove legacy vocabulary decoding, not byte-for-byte
output from an original historical encoder.

### Architecture suggestion: abstract AgentJournal behind a public backend protocol

**Disposition: Rejected for the next RC.** `AgentJournal` is part of the trusted
mutation state machine, not a generic logging sink. A host-implemented public
backend protocol would expose admission, reconciliation, settlement, atomicity,
and lease obligations that are currently enforced by one package-owned actor.
Alternative storage remains a future architecture topic, not a provider release
requirement.

### Architecture suggestion: add opaque per-request provider options

**Disposition: Partially accepted.** Adapter-instance configuration is currently
the safer public contract. OpenAI Responses and Apple PCC work will first use
provider constructors and the existing provider-neutral request. SwiftAgent will
add a neutral request abstraction only if real cross-provider evidence requires
it; it will not add a vendor-options dictionary preemptively.

## Explicit Answers

### Does AnthropicProvider require a code change?

Yes. The response model identity must not be discarded or accepted without a
declared relationship to the requested model. SAI-059 fixes this with exact
matching plus explicit legacy-alias resolution. The review found no additional
blocker in Anthropic tool handling, thinking continuation, SSE terminal
validation, cancellation, or usage mapping.

### What fails first in a months-long process?

Journal append validation and retained mutation identity growth are the most
likely long-running pressure points. They affect latency, startup work, memory,
and storage before they weaken safety. SAI-046 remains the explicit retention
design task.

### Which public APIs carry the most post-1.0 regret risk?

- The concrete `AgentJournal` storage surface if alternate durable backends
  become necessary.
- Public exhaustive error and event enums as new cases are added.
- Fixed `ModelRequest` fields if a provider-neutral request need cannot be
  expressed by provider configuration or opaque continuation.
- The overlapping drain-facing methods if their distinct ownership contexts are
  not kept clear in documentation.

No breaking cleanup is justified solely by these risks before the next RC.

### Can provider output bypass the safety chain?

No through the supported Agent API. A clean terminal provider response still
passes schema validation, Evidence, authorization, durable mutation admission,
the host executor, Receipt validation, and Journal settlement. Apple structured
planning does not register SwiftAgent tools with `LanguageModelSession`. A
trusted Host can misconfigure policy or bypass the SDK entirely, which remains
outside the provider-output threat boundary.

## Review Limitations

Panel 2 reviewed the package graph and the principal Core, Tool, Journal,
Anthropic, Apple, WorkspaceAgent, security, provider, and concurrency paths. At
the user's request it returned the findings before exhaustively reading every
test and review document. Codex independently reproduced the two accepted
correctness findings with failing tests before implementing fixes.

## Remediation Review

Panel 2 reviewed the implemented directory-durability and Anthropic identity
changes after the failure-injection tests passed. Its final response was:

> No blocker.

The rc.1 initializer symbol remains available. The Anthropic alias contract is
an additive overload, so the public symbol inventory changes from 956 to 957
with no removed public symbol. The package suite, ExternalClient 6/6, and the
11/11 plus 3/3 concurrency seal passed on 2026-09-19.
