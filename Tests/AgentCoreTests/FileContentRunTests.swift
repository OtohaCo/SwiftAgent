import AgentJournalFileStore
import AgentModels
import Foundation
import Testing
@testable import AgentCore

struct FileContentRunTests {
    private func file(_ name: String = "report", tokens: Int = 2000) throws -> ModelFileReference {
        try .init(uri: URL(string: "https://example.com/files/\(name)")!, mediaType: .pdf,
                  description: "immutable report", estimatedInputTokens: tokens)
    }
    private func provider(native: Bool = true) -> ScriptedProvider {
        ScriptedProvider(descriptor: .init(id: "fixture", capabilities: native ? [.streaming, .multiTurn, .fileInput] : [.streaming, .multiTurn])) {
            request, _ in textResponse(request, "read")
        }
    }
    private func binding(_ provider: ScriptedProvider, policy: AgentFileInputPolicy,
                         budget: AgentContextTokenBudget? = nil) throws -> AgentModelBinding {
        try .init(profileID: "files", profileRevision: "1", model: fixtureModel, provider: provider,
                  deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
                  tokenBudget: budget, fileInput: policy)
    }
    @Test(arguments: [false, true])
    func durableInputReopensAndCorrelationBindsActualAttachments(described: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("file-run-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "files", supportsFileContent: true)
        #expect(journal.supportsFileContent && journal.supportsRunRecords)
        let format = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("format.json"))) as! [String: Any]
        #expect(format["schema"] as? Int == 13)
        let provider = provider(native: !described), file = try file()
        let binding = try binding(provider, policy: described ? .describe : .native())
        let agent = try Agent(binding: binding)
        let session = try agent.makeSession(journal: journal)
        let correlation = try AgentRunCorrelation(key: "file/one", payloadDigest: "host-config")
        let input = try AgentRunInput(text: "read report", attachments: [.file(file)])
        let run = try await session.run(input, correlation: correlation)
        let result = try await run.wait(); try await run.waitForDrain()
        #expect(result.history.flatMap(\.files) == [file])
        let request = try #require(await provider.log.requests.first)
        #expect(request.messages.flatMap(\.files) == (described ? [] : [file]))
        if described { #expect(request.messages.contains(.user([.text(input.text), .text(file.textSubstitute)]))) }
        guard case .terminal(let record, .completed) = try await session.runRecord(runID: run.id) else { Issue.record("missing terminal"); return }
        await #expect(throws: AgentRunAdmissionError.alreadyAdmitted(record)) { try await session.run(input, correlation: correlation) }
        await #expect(throws: AgentRunAdmissionError.conflict(record)) {
            try await session.run(AgentRunInput(text: input.text, attachments: [.file(self.file("different"))]), correlation: correlation)
        }
        await #expect(throws: AgentRunAdmissionError.conflict(record)) { try await session.run(input.text, correlation: correlation) }
        #expect(await provider.log.requests.count == 1)
        _ = try await journal.requestMaintenance(); try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.readMessages(sessionID: session.id).map(\.message) == result.history)
        #expect(try await reopened.runRecord(sessionID: session.id, runID: run.id) == .terminal(record, .completed))
        let fresh = try agent.makeSession(id: session.id, journal: reopened)
        let next = try await fresh.run("continue"); let nextResult = try await next.wait(); try await next.waitForDrain()
        #expect(nextResult.history.flatMap(\.files) == [file])
        try await reopened.close()
    }
    @Test func oldStoreRejectsFileBeforeAdmissionOrProvider() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("file-old-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "old", supportsRunRecords: true)
        let provider = provider(), binding = try binding(provider, policy: .native())
        let session = try Agent(binding: binding).makeSession(journal: journal)
        let key = try AgentRunCorrelation(key: "file/rejected", payloadDigest: "same")
        await #expect(throws: AgentJournalError.unsupportedFormat) {
            try await session.run(AgentRunInput(text: "read", attachments: [.file(self.file())]), correlation: key)
        }
        #expect(try await session.runRecord(correlationKey: key.key) == .notAdmitted)
        #expect(try await journal.readMessages(sessionID: session.id).isEmpty)
        #expect(await provider.log.requests.isEmpty)
        try await journal.close()
    }
    @Test(arguments: [AgentFileInputPolicy.reject, try! .native(maximumEstimatedInputTokens: 1000)])
    func policyFailureDoesNotAdmit(_ policy: AgentFileInputPolicy) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("file-policy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "files", supportsFileContent: true)
        let provider = provider(), session = try Agent(binding: binding(provider, policy: policy)).makeSession(journal: journal)
        let key = try AgentRunCorrelation(key: "file/rejected", payloadDigest: "same")
        do {
            _ = try await session.run(AgentRunInput(text: "read", attachments: [.file(self.file())]), correlation: key)
            Issue.record("File policy admitted rejected input")
        } catch {
            if policy.mode == .reject { #expect(error as? AgentLoopError == .unsupportedCapabilities(.fileInput)) }
            else { #expect(error as? AgentFileInputError == .limitExceeded) }
        }
        #expect(try await session.runRecord(correlationKey: key.key) == .notAdmitted)
        #expect(try await journal.readMessages(sessionID: session.id).isEmpty)
        #expect(await provider.log.requests.isEmpty)
        try await journal.close()
    }
    @Test func nativePolicyRequiresAdapterAndRejectsAssistantFiles() throws {
        let policy = try AgentFileInputPolicy.native(), file = try file()
        #expect(throws: AgentLoopError.unsupportedCapabilities(.fileInput)) {
            try policy.apply(to: [.user([.file(file)])], adapterSendsFiles: false)
        }
        #expect(throws: AgentFileInputError.invalidRole) {
            try policy.apply(to: [.assistant(content: [.file(file)], toolCalls: [])], adapterSendsFiles: true)
        }
    }
    @Test func tokenEstimatorCannotIgnoreDeclaredFileTokens() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("file-budget-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "files", supportsFileContent: true)
        let provider = provider()
        let budget = try AgentContextTokenBudget(maximumContextTokens: 5000, reservedOutputTokens: 100,
                                                 estimator: OmittingFileEstimator())
        let session = try Agent(binding: binding(provider, policy: .native(), budget: budget)).makeSession(journal: journal)
        let key = try AgentRunCorrelation(key: "file/budget", payloadDigest: "same")
        await #expect(throws: AgentModelBindingError.invalidTokenEstimate) {
            try await session.run(AgentRunInput(text: "read", attachments: [.file(self.file())]), correlation: key)
        }
        #expect(try await session.runRecord(correlationKey: key.key) == .notAdmitted)
        #expect(await provider.log.requests.isEmpty)
        try await journal.close()
    }
    @Test func typedTextOnlyInputRetainsExistingStringCorrelationIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("file-text-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "text", supportsRunRecords: true)
        let provider = provider(), session = try Agent(model: fixtureModel, provider: provider).makeSession(journal: journal)
        let key = try AgentRunCorrelation(key: "same/text", payloadDigest: "same")
        let run = try await session.run("exact", correlation: key); try await run.waitForDrain()
        guard case .terminal(let record, .completed) = try await session.runRecord(runID: run.id) else { Issue.record("missing terminal"); return }
        await #expect(throws: AgentRunAdmissionError.alreadyAdmitted(record)) {
            try await session.run(AgentRunInput(text: "exact"), correlation: key)
        }
        #expect(await provider.log.requests.count == 1)
        try await journal.close()
    }
}

private struct OmittingFileEstimator: AgentContextTokenEstimator {
    func estimate(_ input: AgentContextTokenEstimationInput) async throws -> AgentContextTokenEstimate {
        .init(inputTokens: 1, accuracy: .estimated)
    }
}
