import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing

struct AdmissionRejectionPersistenceTests {
    @Test func realRuntimeDenialHasIndependentDurableIdentityAcrossProcessAndMaintenance() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("admission-rejection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "rejection-process",
            policy: try .init(segmentBytes: 4 * 1024, maxSegmentBatches: 2),
            supportsAdmissionRejections: true,
            fault: { stage in
                if case .afterMaintenanceSnapshot = stage {
                    throw AgentJournalError.persistenceUnavailable("defer maintenance until reopen")
                }
            })
        let sessionID = UUID()
        let provider = RejectionProcessProvider()
        let agent = try Agent(model: .init(provider: "rejection-process", name: "script"),
            provider: provider, tools: [RejectionReadTool(), RejectionMutationTool(),
                                       OrdinaryReadFailureTool()],
            configuration: .init(preAdmissionReplanning: .evidenceRejection(toolNames: [RejectionMutationTool.name])))
        let session = try agent.makeSession(id: sessionID, journal: journal)
        let run = try await session.run("Choose a discovered resource", operationID: "operation")
        #expect(try await run.wait().outcome == .completed)
        try await run.waitForDrain()
        let marker = try #require(try await journal.admissionRejection(sessionID: sessionID,
            runID: run.id, callID: .init(rawValue: "invalid-X")))
        #expect(marker.toolName == RejectionMutationTool.name)
        let ordinaryRun = try await session.run("ordinary error")
        #expect(try await ordinaryRun.wait().outcome == .completed)
        try await ordinaryRun.waitForDrain()
        #expect(try await journal.admissionRejection(sessionID: sessionID, runID: ordinaryRun.id,
            callID: .init(rawValue: "ordinary-error")) == nil)
        try await journal.close()
        let before = try process(directory, sessionID: sessionID, runID: run.id, callID: "invalid-X")
        #expect(before.contains("marker=\(RejectionMutationTool.name) paired=true"))
        let ordinary = try process(directory, sessionID: sessionID,
                                   runID: ordinaryRun.id, callID: "ordinary-error")
        #expect(ordinary.contains("marker=none paired=true"))

        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await (reopened.maintenanceStatus()?.sealedSegments ?? 0) > 0)
        for _ in 0..<8 {
            if try await reopened.requestMaintenance()?.sealedSegments == 0 { break }
        }
        #expect(try await reopened.maintenanceStatus()?.sealedSegments == 0)
        try await reopened.close()
        let after = try process(directory, sessionID: sessionID, runID: run.id, callID: "invalid-X")
        #expect(after.contains("marker=\(RejectionMutationTool.name) paired=true"))
        let ordinaryAfter = try process(directory, sessionID: sessionID,
                                        runID: ordinaryRun.id, callID: "ordinary-error")
        #expect(ordinaryAfter.contains("marker=none paired=true"))
    }

    @Test func rejectionMarkerAndPairedMessagesShareThePublicationBoundary() async throws {
        for afterCurrent in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rejection-fault-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fault = RejectionPublicationFault(afterCurrent: afterCurrent)
            let journal = try AgentIncrementalJournal.createForTesting(at: directory,
                operationDomain: "rejection-fault", supportsAdmissionRejections: true,
                fault: { try fault.check($0) })
            let sessionID = UUID()
            let provider = RejectionProcessProvider(armRejection: { fault.arm() })
            let agent = try Agent(model: .init(provider: "rejection-process", name: "script"),
                provider: provider, tools: [RejectionReadTool(), RejectionMutationTool()],
                configuration: .init(preAdmissionReplanning: .evidenceRejection(toolNames: [RejectionMutationTool.name])))
            let run = try await agent.makeSession(id: sessionID, journal: journal)
                .run("Choose a discovered resource", operationID: "operation")
            if afterCurrent {
                await #expect(throws: AgentJournalError.commitUnknown) { try await run.wait() }
            } else {
                await #expect(throws: AgentJournalError.persistenceUnavailable("rejection fault")) {
                    try await run.wait()
                }
            }
            try await run.waitForDrain()
            try await journal.close()
            let observed = try process(directory, sessionID: sessionID,
                                       runID: run.id, callID: "invalid-X")
            #expect(observed.contains(afterCurrent
                ? "marker=\(RejectionMutationTool.name) paired=true"
                : "marker=none paired=false"), "\(observed)")
        }
    }

    private func process(_ directory: URL, sessionID: UUID, runID: UUID, callID: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let executable = try #require([
            root.appendingPathComponent(".build/out/Products/Debug/JournalTestProcess"),
            root.appendingPathComponent(".build/debug/JournalTestProcess"),
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }))
        let child = Process(), output = Pipe(), errors = Pipe()
        child.executableURL = executable
        child.arguments = ["read-admission-rejection", directory.path, sessionID.uuidString,
                           runID.uuidString, callID]
        child.standardOutput = output
        child.standardError = errors
        try child.run()
        child.waitUntilExit()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(child.terminationStatus == 0,
            "\(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
        return result
    }
}

private struct RejectionProcessProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "rejection-process", capabilities: [.multiTurn, .tools])
    let armRejection: @Sendable () -> Void
    init(armRejection: @escaping @Sendable () -> Void = {}) { self.armRejection = armRejection }
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "fixture", model: request.model)
            let call: ToolCall?
            switch request.messages.last {
            case .user(let content) where content == [.text("ordinary error")]:
                call = .init(id: .init(rawValue: "ordinary-error"), name: OrdinaryReadFailureTool.name,
                             argumentsJSON: "{}", completeness: .complete)
            case .user: call = .init(id: .init(rawValue: "search"), name: RejectionReadTool.name,
                                     argumentsJSON: "{}", completeness: .complete)
            case .tool(let result) where result.callID.rawValue == "search":
                armRejection()
                call = .init(id: .init(rawValue: "invalid-X"), name: RejectionMutationTool.name,
                             argumentsJSON: #"{"id":"X"}"#, completeness: .complete)
            case .tool(let result) where result.callID.rawValue == "invalid-X" && result.isError:
                call = nil
            case .tool(let result) where result.callID.rawValue == "ordinary-error" && result.isError:
                call = nil
            default: throw ModelProviderError(kind: .invalidRequest, message: "unexpected request")
            }
            try emit(.responseStarted(info))
            if let call {
                try emit(.toolCallStarted(call.id, name: call.name))
                try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                try emit(.toolCallCompleted(call))
                try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
            } else {
                try emit(.textDelta("denied"))
                try emit(.responseCompleted(.init(info: info, content: [.text("denied")], stopReason: .endTurn)))
            }
        }
    }
}

private final class RejectionPublicationFault: @unchecked Sendable {
    private let lock = NSLock()
    private let afterCurrent: Bool
    private var armed = false
    init(afterCurrent: Bool) { self.afterCurrent = afterCurrent }
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func check(_ stage: JournalFileFaultStage) throws {
        if afterCurrent {
            guard case .afterCurrentReplace = stage else { return }
        } else {
            guard case .beforeAppend = stage else { return }
        }
        lock.lock()
        let fail = armed
        armed = false
        lock.unlock()
        if fail { throw AgentJournalError.persistenceUnavailable("rejection fault") }
    }
}

private struct OrdinaryReadFailureTool: AgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = String
    static let name = "ordinary_read_failure"
    static let description = "Report a recoverable fixture error"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.string
    let policy = try! ToolPolicy.readOnly(authorization: .notRequired, recoverableErrors: .modelVisible)
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        throw try RecoverableToolError(code: "evidence_unavailable",
            message: "Evidence for reference X is unavailable; this call was denied before execution.")
    }
}

private struct RejectionReadTool: AgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = String
    static let name = "rejection_search"
    static let description = "Find two fixture resources"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.string
    let policy = try! ToolPolicy.readOnly(authorization: .notRequired)
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        .init(output: "A and B", evidence: [
            .init(namespace: "resource", id: "A", issuedAt: Date()),
            .init(namespace: "resource", id: "B", issuedAt: Date()),
        ])
    }
}

private struct RejectionMutationTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    typealias Output = String
    static let name = "rejection_commit"
    static let description = "Never execute X"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.string
    let policy = try! ToolPolicy.mutation(authorization: .notRequired)
    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] {
        [.init(reference: .init(namespace: "resource", id: input.id))]
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "resource", id: input.id))]
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "resource", id: input.id)], revision: .present)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        throw AgentJournalError.invalidRecord
    }
}
