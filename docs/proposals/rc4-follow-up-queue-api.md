# RC4 durable follow-up queue: public API contract

Status: implemented in the RC4 queue branch; these signatures summarize
the public types in `Sources/AgentCore/AgentFollowUp.swift` and
`AgentFollowUpDispatcher.swift`. The executable
`Examples/ExternalClient/Sources/FollowUpQueueFixture/main.swift` uses the
real API without a key or network request. The final PR head still requires
its own qualification and review. Integrated parent `main` is
`44e48f0783be0c467d45ac4b7d9f98c42e01718e`.

## Public Core surface

Selected declarations below omit initializer bodies and storage details; the
linked source and executable fixture are authoritative, not a Host array:

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
    case withdrawn                           // includes already-withdrawn idempotent retry
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
    public let capabilities: AgentCapabilityBinding    // required, fresh, same Session instance
    public let expectedConversationRevision: UInt64?  // Host's current binding check
}

public struct AgentFollowUpDispatchPolicy: Sendable {
    public let maxModelTurns: Int
    public let maxToolCalls: Int
    public let runTimeout: Duration            // clock begins BEFORE resolver work
}

public actor AgentFollowUpDispatcher {
    public func pause() async                  // no next admission, retain queued records
    public func resume() async throws          // explicit; validate owner generation
    public func resumeAfterInspection(inputID: String) async throws
    public func stop() async                   // revoke resolver/dispatch claim after drain
    public func cancelCurrent() async          // delegates to actual AgentRun.cancel()
    public func waitForDrain() async throws    // no requirement to empty the backlog
    public func status() async -> AgentFollowUpDispatchStatus
}
```

Actor isolation and typed errors are implemented in the linked source. All
durable reads throw; a corrupt/unavailable store never
becomes an empty list. Enqueue and withdraw distinguish definite noncommit,
definite publication and `commitUnknown`. Unknown publication is not reported
as success; callers reopen/query the *same* `inputID`, never invent a new one.
The scoped durable store is required. The resolver must explicitly provide a
fresh capability binding; `nil` cannot expose the Agent's default tool set.
No in-memory success surface is offered
in v1; a read-only Agent may still use memory for ordinary `run`.

## Host usage pattern (abbreviated)

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
await dispatcher.stop()                     // pause alone retains the consumer claim
try await dispatcher.waitForDrain()

try await journal.close()
let reopened = try AgentIncrementalJournal.open(at: directory)
let restored = try agent.makeSession(id: session.id, journal: reopened)
// Still paused after reopen; a new explicit Host decision starts dispatch.
let resumed = try await restored.startFollowUpDispatch(policy: policy,
    resolver: freshApprovedResolver)
```

The executable fixture arranges pause timing with a resolver barrier;
this shortened sketch illustrates ownership. The
dispatcher must use `AgentRun.wait()` and `waitForDrain()` without becoming a
second consumer of `AgentRun.events`. Existing `AgentSession.run` and
`AgentRun.steer` meanings remain unchanged. Direct `run` while a dispatcher
owns the Session returns a typed `dispatchOwned` error; an internal queued
startup uses the same Session admission/reservation path. A paused dispatcher
still owns the Session until `stop` and actual drain release its claim.

On process reopen an admitted input without a reliable completed-and-drained
release marker blocks later heads. `resume()` throws `needsInspection`.
`resumeAfterInspection(inputID:)` requires an explicit Host decision and no
unresolved Session mutation; it unblocks *later* queued inputs without
reclassifying the original admitted item, granting permission or replaying
its Run. `followUps(after:limit:)` uses an exclusive ordinal cursor (maximum
100 per page); the list omits prompt text, which requires `followUpText`.

`configurationRef` may describe a project or model profile, but does not
recreate `AgentCapabilityBinding` or trusted Evidence. A newly revoked scope
cannot be replaced automatically; Host approval and a current Session-bound
binding are required. A distinct capability version never rewrites the queued
`operationID` or narrows the Journal operation domain.
