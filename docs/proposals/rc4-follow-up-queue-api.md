# RC4 durable follow-up queue: public API draft

Status: review-only sketch, **not a compiled Swift API**. Depends on both PR
#20 (`033bf567b64ebd1b9dcee6f31ed8c2168600c694`) and PR #21
(`056c790e1f6d93b10989697914aa46a0e4eea94a`) landing on `main` first.
No queue methods or schema-2 writer exist at this SHA. After integration,
verify the final signatures and revise this draft before implementation.

## Proposed Core surface

The following Swift-shaped declarations describe semantics, not promised
source compatibility or a temporary Host array:

```swift
public struct AgentFollowUpInput: Sendable {
    public let inputID: String                 // caller-stable within storeID + Session
    public let text: String                    // exact UTF-8 semantic payload
    public let operationID: String             // stable, nonblank; separate from inputID
    public let configurationRef: String       // bounded Host label, never permission
}

public enum AgentFollowUpState: Sendable {
    case queued
    case admitted(runID: UUID, formalMessageID: UUID)
    case withdrawn
}

public struct AgentFollowUpRecord: Sendable {
    public let storeID: UUID
    public let sessionID: UUID
    public let inputID: String
    public let ordinal: UInt64
    public let state: AgentFollowUpState
    public let operationID: String
    public let configurationRef: String
    // No prompt body, credential, scope handle or executor in list diagnostics.
}

public enum AgentFollowUpWithdrawal: Sendable {
    case withdrawn(AgentFollowUpRecord)        // includes already-withdrawn idempotent retry
    case alreadyAdmitted(runID: UUID, formalMessageID: UUID)
}

extension AgentSession {
    public func enqueueFollowUp(_ input: AgentFollowUpInput) async throws -> AgentFollowUpRecord
    public func followUp(inputID: String) async throws -> AgentFollowUpRecord?
    public func followUps(after ordinal: UInt64?, limit: Int) async throws -> [AgentFollowUpRecord]
    public func followUpText(inputID: String) async throws -> String  // explicit private-body read
    public func withdrawFollowUp(inputID: String) async throws -> AgentFollowUpWithdrawal

    // Acquires the only `(storeID, sessionID)` consumer claim; the Host opts in.
    public func startFollowUpDispatch(
        policy: AgentFollowUpDispatchPolicy,
        resolver: any AgentFollowUpResolver
    ) async throws -> AgentFollowUpDispatcher
}

public protocol AgentFollowUpResolver: Sendable {
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration
}

public struct AgentFollowUpResolution: Sendable {
    public let record: AgentFollowUpRecord
    public let text: String
    public let attemptID: UUID                 // in-process fencing, not stored authorization
    public let deadline: ContinuousClock.Instant
}

public struct AgentFollowUpConfiguration: Sendable {
    public let model: AgentModelBinding
    public let capabilities: AgentCapabilityBinding?   // fresh, same Session instance
    public let expectedConversationRevision: UInt64?  // Host's current binding check
}

public struct AgentFollowUpDispatchPolicy: Sendable {
    public let maxModelTurns: Int
    public let maxToolCalls: Int
    public let runTimeout: Duration            // clock begins BEFORE resolver work
}

public struct AgentFollowUpDispatcher: Sendable {
    public func pause() async                  // no next admission, retain queued records
    public func resume() async throws          // explicit; validate owner generation
    public func stop() async                   // revoke resolver/dispatch claim after drain
    public func cancelCurrent() async          // delegates to actual AgentRun.cancel()
    public func waitForDrain() async throws    // no requirement to empty the backlog
    public func status() async -> AgentFollowUpDispatchStatus
}
```

These signatures need final Swift isolation/error design after the integrated
`main` exists. All durable reads throw; a corrupt/unavailable store never
becomes an empty list. Enqueue and withdraw distinguish definite noncommit,
definite publication and `commitUnknown`. Unknown publication is not reported
as success; callers reopen/query the *same* `inputID`, never invent a new one.
The scoped durable store is required. No in-memory success surface is offered
in v1; a read-only Agent may still use memory for ordinary `run`.

## Host usage sketch (future API only)

```swift
let current = try await session.run("Current request")
_ = try await session.enqueueFollowUp(.init(inputID: "input-42", text: "Next A",
    operationID: "logical-A", configurationRef: "project-v7"))
_ = try await session.enqueueFollowUp(.init(inputID: "input-43", text: "Next B",
    operationID: "logical-B", configurationRef: "project-v7"))
_ = try await session.withdrawFollowUp(inputID: "input-43")

// A Host explicitly approves fresh bindings when it starts dispatch.
// Its resolver does not obtain a Journal writer, tool executor or Receipt API.
let dispatcher = try await session.startFollowUpDispatch(policy: policy, resolver: hostResolver)
_ = try await current.wait()
try await current.waitForDrain()
await dispatcher.pause()
try await dispatcher.waitForDrain()

try await journal.close()
let reopened = try AgentIncrementalJournal.open(at: directory)
let restored = try agent.makeSession(id: session.id, journal: reopened)
// Still paused after reopen; a new explicit Host decision starts dispatch.
let resumed = try await restored.startFollowUpDispatch(policy: policy,
    resolver: freshApprovedResolver)
```

The executable acceptance fixture must arrange pause timing deterministically;
this sketch illustrates ownership and is not a runnable example today. The
dispatcher must use `AgentRun.wait()` and `waitForDrain()` without becoming a
second consumer of `AgentRun.events`. Existing `AgentSession.run` and
`AgentRun.steer` meanings remain unchanged. Direct `run` while a dispatcher
owns the Session returns a typed `dispatchOwned` error; an internal queued
startup uses the same Session admission/reservation path. A paused dispatcher
still owns the Session until `stop` and actual drain release its claim.

`configurationRef` may describe a project or model profile, but does not
recreate `AgentCapabilityBinding` or trusted Evidence. A newly revoked scope
cannot be replaced automatically; Host approval and a current Session-bound
binding are required. A distinct capability version never rewrites the queued
`operationID` or narrows the Journal operation domain.
