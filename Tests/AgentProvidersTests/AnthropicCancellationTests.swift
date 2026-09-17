import AgentCore
import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import XCTest
import AgentProviders

struct AnthropicCancellationTests {
    @Test func cancellingRunClosesHTTPStreamWithoutDispatchingAPartialProposal() async throws {
        let entered = XCTestExpectation(description: "HTTP stream entered")
        let cancelled = XCTestExpectation(description: "HTTP stream cancelled")
        let execution = ProviderExecutionProbe()
        let provider = try AnthropicProvider(apiKey: "fixture-key", transport: PendingHTTP(entered: entered, cancelled: cancelled))
        let run = try await Agent(model: .init(provider: "anthropic", name: "fixture"), provider: provider,
                                  tools: [ProviderCalculator(probe: execution)]).makeSession().run("Compute")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 2) == .completed)
        await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        #expect(await XCTWaiter.fulfillment(of: [cancelled], timeout: 2) == .completed)
        #expect(await execution.count == 0)
    }
}

private struct PendingHTTP: ProviderHTTPTransport {
    let entered: XCTestExpectation
    let cancelled: XCTestExpectation
    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in cancelled.fulfill() }
            continuation.yield(.response(status: 200, headers: ["Content-Type": "text/event-stream"]))
            continuation.yield(.data(providerSSE([
                #"{"type":"message_start","message":{"id":"pending","type":"message","role":"assistant","model":"fixture","content":[],"usage":{"input_tokens":5,"output_tokens":0}}}"#,
                #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu-1","name":"calculator","input":{}}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{"}}"#,
            ])))
            entered.fulfill()
        }
    }
}
