# SwiftAgent Context Policy

last-verified: 2026-09-18

Runtime configuration and conversation state have different lifetimes.

| Lifetime | What it is | Who owns it |
| --- | --- | --- |
| Runtime configuration | Current system instructions, developer instructions if the model supports them, and `AgentConfiguration` | The `Agent` that creates the Session |
| Conversation state | User, assistant, and tool history | The Session, restored from the journal checkpoint |

A checkpoint may still contain the system message that was sent on an earlier
run. That record is a historical snapshot of runtime configuration, not the
active configuration. On restore, Core strips checkpoint `system` /
`developer` messages and prepends the instructions of the Agent that is
opening the Session. Conversation user / assistant / tool turns are kept.
The provider request therefore has exactly one current system message.

## Bounds

`AgentContextPolicy` distinguishes two failures:

- `AgentContextError.inputTooLarge` — one user input exceeds `maxInputUTF8Bytes`.
  Fail fast. The Session is unchanged.
- `AgentContextError.historyTooLarge` — after the host-neutral compact step,
  active history still exceeds `maxActiveHistoryUTF8Bytes` (and never the
  journal's 16 MiB frame cap). Typed failure, not a silent truncate.

Defaults: 8 MiB per input, 12 MiB encoded active history, 6 recent user turns
retained. Raising `AgentJournal.maximumFrameSize` is not a substitute for this
policy.

## Compaction

When encoded history exceeds the active limit, Core:

1. Keeps current runtime instructions.
2. Keeps the recent turn window unioned with any unresolved tool pair.
3. Asks `AgentContextCompactor` to summarize only the dropped conversation.
4. Stores that summary as a user message so restore will not strip it.
5. Writes a durable checkpoint and continues the Session.

Core does not invent music, file, or product wording. Hosts supply a
compactor when they need domain summaries; `AgentRetainedTurnCompactor` is the
mechanical default.

Unresolved mutation intents live in the journal mutation index. Compaction
must not drop an assistant/tool pair that still has an open call ID.

## Journal growth

Each durable checkpoint still appends a frame. Compaction bounds the payload
of later frames, so growth is not a full-history copy every turn. Physical
file rollover / journal compaction is a separate follow-up; after a
`corruptTail` recovery, durable appends require `discardCorruptTail()`.
