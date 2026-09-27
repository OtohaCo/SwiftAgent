# ADR 0005: Source-bound request context

Status: accepted for RC4 implementation

## Decision

The formal Journal and Session conversation remain execution facts. Context
materials, Host-provided summaries, projection plans and assembly reports are
derived request data. They never create Evidence, authorization, receipts or
mutation settlements. One immutable Run binding supplies a composite projector;
Core still validates its source revision/digest, tool pairs, provider
continuation, byte limit and token estimate before sending precisely that
projection to the provider. Neither material collection nor estimation writes
the Journal. A failed pre-admission projection leaves the proposed input
uncommitted; later failures leave admitted facts intact.

Each Host material carries an opaque identity, source kind, source version,
Session scope (captured by one immutable Run binding), required/optional policy and bounded
content. The Host assigns the kind; document text cannot promote itself to a
system instruction, trusted tool result or receipt. The assembler orders by
explicit priority, source kind and stable identity, independent of delivery
order. Identical identity/version/content is deduplicated; identity/version
conflicts fail closed. Required content cannot be silently dropped. Optional
content is omitted only under the declared policy, with a redacted reason.
Generated source notices are model-visible, while diagnostic identity hashes,
counts and byte/token estimates are separate and bounded.

A Host requests a history span from a Session's indexed Journal messages. It
contains stable formal message IDs, range and a digest of that exact range.
Summaries are explicit lossy materials tied to a span and generator version.
On every projection the span's exact message content and boundaries must still
match. New messages outside the span do not invalidate it; edits inside do.
Only a closed, past conversation group may be replaced. Host-pinned correction
and constraint IDs cannot be covered by a summary. Current instructions,
the latest user request, unresolved tool calls, denied/uncertain effects and
provider continuation stay visible. Large completed read-only tool output may
be excerpted in the request while keeping the call ID and result state. Its
formal Journal content remains unchanged. No automatic LLM summarizer or
persistent summary cache is introduced.

Source-bound projectors declare the indexed message ranges and tool-result
call IDs they need through `AgentContextSourceReferencing`. Wrappers explicitly
forward those read-only requirements. Core verifies the requested Session and
actual formal message content before supplying IDs; a wrapper cannot obtain a
Journal writer or trusted settlement interface. A text summary covers complete
user-to-assistant groups, never half of a group. Required material reserves its
text-byte allowance before optional material is selected. Source reports bind
material, summary, excerpt and policy revisions; the final request remains
subject to the separate full-request byte and token limits.

The v1 Journal persists mutation identity/receipt and formal tool results, but
does not persist a read-only effect classification for each call. A current
tool name cannot establish an earlier call's effect. Core records successful
read-only result identity and digest after its Session checkpoint in a
process-local ledger. An excerpt requires that evidence on both creation and
request assembly. A reopened Session has no such proof and refuses even a
genuinely old read-only result until a future version supplies durable trusted
metadata. This conservative limit changes neither Journal format nor mutation
settlement.

The composite projector bounds material count, content bytes, total bytes and
one assembly pass. Core performs one byte count and one token estimate on the
resulting request, including tools and structured output in the existing
estimator contract. Estimates are not provider usage or exact costs. Deadline
and cancellation use the existing Run owner, and late collection cannot edit
another Run. The report sink receives sanitized bounded metadata, never full
prompts, paths, credentials or opaque continuation. Source hashes are version
markers, not authorization or malicious-tamper authentication.

In-Run projection and estimation are counted as physical work. A cooperative
deadline can logically finish a Run before a Host projector/estimator exits;
Session drain retains its identity and store lease until that work completes.
The cancelled worker checks its cancellation again before any Provider send.

## Scope

The first slice accepts Host-prepared source snapshots through the Run binding.
Fetching files, retrieval and Skill approval remain Host responsibilities;
contributors receive no executor or Journal writer. It adds no provider,
plugin registry, context database, Journal format change, input queue, model
switch within a Run or automatic summary service. The Journal's indexed
message query supplies identities without introducing parallel history IDs.
