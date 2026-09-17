import AgentModels
import Foundation

public actor AgentSession {
    public nonisolated let id = UUID()
    public private(set) var history: [ModelMessage]
    public private(set) var activeRunID: UUID?
    private let loop: AgentLoop
    private let structuredOutput: StructuredOutputSchema?
    private let maxModelTurns: Int
    private let maxToolCalls: Int
    private let runTimeout: Duration
    private var appliedSteeringIDs: Set<UUID> = []

    init(loop: AgentLoop, instructions: String, structuredOutput: StructuredOutputSchema?, maxModelTurns: Int, maxToolCalls: Int, runTimeout: Duration) {
        self.loop = loop
        self.structuredOutput = structuredOutput
        history = instructions.isEmpty ? [] : [.system(instructions)]
        self.maxModelTurns = maxModelTurns
        self.maxToolCalls = maxToolCalls
        self.runTimeout = runTimeout
    }

    public func run(_ text: String, budget: AgentBudget? = nil) throws -> AgentRun {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentSessionError.emptyInput }
        guard activeRunID == nil else { throw AgentSessionError.runInProgress }
        let budget = try budget ?? AgentBudget(maxModelTurns: maxModelTurns, maxToolCalls: maxToolCalls,
                                               deadline: .now.advanced(by: runTimeout))
        try budget.checkActive()
        let runID = UUID()
        let control = AgentRunControl()
        let channel = AsyncStream<AgentEvent>.makeStream()
        let emitter = AgentEventEmitter(channel.continuation, requiresConsumer: false)
        history.append(.user([.text(text)]))
        activeRunID = runID
        appliedSteeringIDs.removeAll()
        let messages = history
        Task { await control.start { await self.perform(messages, runID: runID, budget: budget, emitter: emitter, control: control) } }
        return AgentRun(id: runID, sessionID: id, events: channel.stream, control: control)
    }
    private func perform(_ messages: [ModelMessage], runID: UUID, budget: AgentBudget,
                         emitter: AgentEventEmitter, control: AgentRunControl) async -> Result<AgentLoopResult, Error> {
        let lifecycle = AgentLoopLifecycle(
            control: control,
            checkpoint: { messages, steering in try await self.record(messages, steering: steering, runID: runID, budget: budget) },
            beforeFinish: {
                let pending = await control.beginFinish()
                await self.finish(runID: runID, pending: pending)
            }
        )
        do {
            let result = try await loop.execute(messages: messages, sessionID: id, runID: runID, budget: budget,
                                                structuredOutput: structuredOutput, emitter: emitter, lifecycle: lifecycle)
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    private func record(_ messages: [ModelMessage], steering: [AgentSteeringInput], runID: UUID, budget: AgentBudget) throws {
        try budget.checkActive()
        guard activeRunID == runID else { throw CancellationError() }
        history = messages
        appliedSteeringIDs.formUnion(steering.map(\.id))
    }

    private func finish(runID: UUID, pending: [AgentSteeringInput]) {
        guard activeRunID == runID else { return }
        for input in pending where !appliedSteeringIDs.contains(input.id) {
            history.append(.user([.text(input.text)]))
        }
        activeRunID = nil
        appliedSteeringIDs.removeAll()
    }
}

public enum AgentSessionError: Error, Equatable, Sendable {
    case emptyInput
    case runInProgress
}
