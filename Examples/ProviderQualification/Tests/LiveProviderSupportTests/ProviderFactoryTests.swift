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
        #expect(response.eventTypes == ["response.created", "response.output_item.added"])
        #expect(response.models == ["deepseek-test"])
        #expect(response.responseStatuses == ["in_progress"])
        #expect(response.itemTypes == ["message"])
        #expect(response.itemStatuses == ["in_progress"])
        #expect(response.hasSequenceNumberForEveryEvent)
        #expect(response.eventShapes == [
            "response.created[sequence]",
            "response.output_item.added[sequence,index=0,item=message,item_status=in_progress]",
        ])
        #expect(response.missingSequenceEventTypes.isEmpty)
        #expect(!response.description.contains("private-response-text"))
        #expect(!response.description.contains("private-signature"))
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
            data: {"type":"response.created","sequence_number":0,"response":{"id":"r","model":"deepseek-test","status":"in_progress","signature":"private-signature"}}

            event: response.output_item.added
            data: {"type":"response.output_item.added","sequence_number":1,"output_index":0,"item":{"id":"m","type":"message","role":"assistant","status":"in_progress","content":[{"type":"output_text","text":"private-response-text"}]}}

            """.utf8)))
            continuation.finish()
        }
    }
}
