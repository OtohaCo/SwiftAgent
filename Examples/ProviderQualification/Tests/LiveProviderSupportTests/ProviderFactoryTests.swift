import AgentModels
import AgentProviders
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LiveProviderSupport
import Testing

struct ProviderFactoryTests {
    @Test(arguments: [
        (QualificationProvider.openAI, "OPENAI_API_KEY", "OPENAI_MODEL", "openai"),
        (.deepSeek, "DEEPSEEK_API_KEY", "DEEPSEEK_MODEL", "deepseek"),
        (.anthropic, "ANTHROPIC_API_KEY", "SWIFT_AGENT_ANTHROPIC_MODEL", "anthropic"),
        (.local, "SWIFTAGENT_LOCAL_API_KEY", "SWIFTAGENT_LOCAL_MODEL", "local-responses"),
    ])
    func liveFactoryBuildsTheExistingProviderAdapter(
        provider: QualificationProvider,
        keyName: String,
        modelName: String,
        expectedDescriptor: String
    ) throws {
        let options = QualificationOptions(
            provider: provider,
            mode: .live,
            scenario: .text,
            modelOverride: nil,
            endpointOverride: URL(string: "https://provider.example/v1/responses")!,
            environmentFile: nil,
            budgetFile: nil,
            service: .official,
            reasoning: "none"
        )
        let environment = LiveEnvironment(process: [keyName: "secret", modelName: "test-model"])
        let configuration = try QualificationConfiguration.resolve(options: options, environment: environment)
        let selection = try LiveProviderFactory.makeModelProvider(
            configuration: configuration,
            budget: try LiveRequestBudget(fileURL: nil),
            evidence: RequestEvidenceLedger(),
            transport: EmptyHTTPTransport()
        )

        #expect(selection.model.name == "test-model")
        #expect(selection.provider.descriptor.id == expectedDescriptor)
    }

    @Test func localLiveFactoryAllowsNoAuthenticationAndUsesConfiguredBaseURL() throws {
        let options = QualificationOptions(
            provider: .local,
            mode: .live,
            scenario: .text,
            modelOverride: nil,
            endpointOverride: nil,
            environmentFile: nil,
            budgetFile: nil,
            service: .local
        )
        let environment = LiveEnvironment(process: [
            "SWIFTAGENT_LOCAL_MODEL": "local-model",
            "SWIFTAGENT_LOCAL_BASE_URL": "http://192.168.1.10:1234/v1",
        ])
        let configuration = try QualificationConfiguration.resolve(options: options, environment: environment)
        let selection = try LiveProviderFactory.makeModelProvider(
            configuration: configuration,
            budget: try LiveRequestBudget(fileURL: nil),
            evidence: RequestEvidenceLedger(),
            transport: EmptyHTTPTransport()
        )

        #expect(selection.model == .init(provider: "local-responses", name: "local-model"))
        #expect(selection.provider.descriptor.id == "local-responses")
        #expect(selection.serviceLabel == "local")
    }

    @Test func budgetedTransportCountsAndRecordsOnlySanitizedRequestShape() async throws {
        let budget = try LiveRequestBudget(fileURL: nil, perProviderLimit: 2, totalLimit: 2)
        let evidence = RequestEvidenceLedger()
        let transport = BudgetedProviderHTTPTransport(
            provider: .openAI,
            budget: budget,
            evidence: evidence,
            base: OneResponseTransport()
        )
        var request = URLRequest(url: URL(string: "https://api.openai.example/v1/responses")!)
        request.httpBody = Data(#"{"model":"m","input":[{"type":"message","role":"assistant","content":"hidden"},{"type":"function_call","call_id":"call-1","name":"add_numbers","arguments":"{}"},{"type":"function_call_output","call_id":"call-1","output":"hidden"}]}"#.utf8)

        for try await _ in transport.stream(request) {}

        #expect((await budget.snapshot()).totalAttempts == 1)
        let entries = await evidence.entries
        #expect(entries.count == 1)
        #expect(entries[0].hasAssistantHistory)
        #expect(entries[0].hasToolResult)
        #expect(entries[0].hasBoundToolResult)
        #expect(entries[0].model == "m")
        #expect(!entries[0].description.contains("hidden"))
    }

    @Test func requestEvidenceRejectsUnboundToolResultsAndRecognizesTheSyntheticHistoryMarker() async throws {
        let budget = try LiveRequestBudget(fileURL: nil, perProviderLimit: 2, totalLimit: 2)
        let evidence = RequestEvidenceLedger()
        let transport = BudgetedProviderHTTPTransport(
            provider: .openAI,
            budget: budget,
            evidence: evidence,
            base: OneResponseTransport()
        )
        var request = URLRequest(url: URL(string: "https://api.openai.example/v1/responses")!)
        request.httpBody = Data(#"{"model":"m","input":[{"type":"message","role":"user","content":"Remember BLUE-17"},{"type":"message","role":"assistant","content":"acknowledged"},{"type":"function_call","call_id":"call-1","name":"add_numbers","arguments":"{}"},{"type":"function_call_output","call_id":"different-call","output":"{}"}]}"#.utf8)

        for try await _ in transport.stream(request) {}

        let entry = try #require((await evidence.entries).first)
        #expect(entry.hasQualificationHistoryMarker)
        #expect(entry.hasToolCall)
        #expect(entry.hasToolResult)
        #expect(!entry.hasBoundToolResult)
        #expect(!entry.description.contains("BLUE-17"))
        #expect(!entry.description.contains("call-1"))
    }

    @Test func responseEvidenceKeepsOnlyBoundedProtocolMetadata() async throws {
        let evidence = RequestEvidenceLedger()
        let budget = try LiveRequestBudget(fileURL: nil, perProviderLimit: 1, totalLimit: 1)
        let transport = BudgetedProviderHTTPTransport(
            provider: .deepSeek,
            budget: budget,
            evidence: evidence,
            base: MetadataResponseTransport()
        )
        let request = URLRequest(url: URL(string: "https://api.deepseek.example/responses")!)

        for try await _ in transport.stream(request) {}

        let responses = await evidence.responses
        let response = try #require(responses.first)
        #expect(response.httpStatus == 200)
        #expect(response.eventTypes == [
            "response.created", "response.output_item.added", "response.output_item.done", "response.completed",
        ])
        #expect(response.models == ["deepseek-test"])
        #expect(response.responseStatuses == ["in_progress", "completed"])
        #expect(response.itemTypes == ["message", "reasoning"])
        #expect(response.itemStatuses == ["in_progress", "completed"])
        #expect(response.hasSequenceNumberForEveryEvent)
        #expect(response.eventShapes == [
            "response.created[sequence,output_count=0]",
            "response.output_item.added[sequence,index=0,item=message,item_status=in_progress,"
                + "item_keys=content|id|role|status|type,item_content=1]",
            "response.output_item.done[sequence,index=1,item=reasoning,item_status=completed,"
                + "item_keys=encrypted_content|id|status|summary|type,item_summary=0,item_encrypted=present]",
            "response.completed[sequence,output_count=2,"
                + "output_schema=message{keys=content|id|role|status|type;status=in_progress;content=1}"
                + "+reasoning{keys=encrypted_content|id|status|summary|type;status=completed;summary=0;encrypted=present},"
                + "encrypted_matches_done=false]",
        ])
        #expect(response.missingSequenceEventTypes.isEmpty)
        #expect(!response.description.contains("private-response-text"))
        #expect(!response.description.contains("private-signature"))
        #expect(!response.description.contains("private-encrypted-content"))
        #expect(!response.description.contains("terminal-private-encrypted-content"))
    }

    @Test func responseEvidenceMarksMissingTerminalEncryptionAsAMismatch() async throws {
        let evidence = RequestEvidenceLedger()
        let budget = try LiveRequestBudget(fileURL: nil, perProviderLimit: 1, totalLimit: 1)
        let transport = BudgetedProviderHTTPTransport(
            provider: .openAI,
            budget: budget,
            evidence: evidence,
            base: MissingTerminalEncryptedResponseTransport()
        )
        let request = URLRequest(url: URL(string: "https://api.openai.example/v1/responses")!)

        for try await _ in transport.stream(request) {}

        let response = try #require((await evidence.responses).first)
        #expect(response.eventShapes.last?.contains("encrypted_matches_done=false") == true)
        #expect(!response.description.contains("private-encrypted-content"))
    }
}

private struct EmptyHTTPTransport: ProviderHTTPTransport {
    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct OneResponseTransport: ProviderHTTPTransport {
    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.response(status: 200, headers: [:]))
            continuation.finish()
        }
    }
}

private struct MetadataResponseTransport: ProviderHTTPTransport {
    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.response(status: 200, headers: [:]))
            continuation.yield(.data(Data("""
            event: response.created
            data: {"type":"response.created","sequence_number":0,"response":{"id":"r","model":"deepseek-test","status":"in_progress","output":[],"signature":"private-signature"}}

            event: response.output_item.added
            data: {"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"id":"m","type":"message","role":"assistant","status":"in_progress","content":[{"type":"output_text","text":"private-response-text"}]}}

            event: response.output_item.done
            data: {"type":"response.output_item.done","sequence_number":2,"output_index":1,"item":{"id":"r","type":"reasoning","status":"completed","summary":[],"encrypted_content":"private-encrypted-content"}}

            event: response.completed
            data: {"type":"response.completed","sequence_number":3,"response":{"id":"r","model":"deepseek-test","status":"completed","output":[{"id":"m","type":"message","role":"assistant","status":"in_progress","content":[{"type":"output_text","text":"private-response-text"}]},{"id":"r","type":"reasoning","status":"completed","summary":[],"encrypted_content":"terminal-private-encrypted-content"}]}}

            """.utf8)))
            continuation.finish()
        }
    }
}

private struct MissingTerminalEncryptedResponseTransport: ProviderHTTPTransport {
    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.response(status: 200, headers: [:]))
            continuation.yield(.data(Data("""
            event: response.output_item.done
            data: {"type":"response.output_item.done","sequence_number":0,"output_index":0,"item":{"id":"r","type":"reasoning","status":"completed","summary":[],"encrypted_content":"private-encrypted-content"}}

            event: response.completed
            data: {"type":"response.completed","sequence_number":1,"response":{"id":"response","model":"openai-test","status":"completed","output":[{"id":"r","type":"reasoning","status":"completed","summary":[]}]}}

            """.utf8)))
            continuation.finish()
        }
    }
}
