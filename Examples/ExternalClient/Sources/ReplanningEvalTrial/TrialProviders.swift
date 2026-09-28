import AgentModels
import AgentProviders
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ObservedProvider: ModelProvider {
    let wrapped: any ModelProvider
    let probe: TrialProbe
    let gate: TrialGate?
    var descriptor: ModelProviderDescriptor { wrapped.descriptor }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            await probe.request(request)
            if let gate { await gate.wait() }
            for try await event in wrapped.stream(request: request) { try emit(event) }
        }
    }
}

struct TrialHTTPTransport: ProviderHTTPTransport {
    let probe: TrialProbe
    let wrapped: any ProviderHTTPTransport

    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    try await probe.reserveHTTP()
                    for try await event in wrapped.stream(request) {
                        try Task.checkCancellation()
                        if case .terminated = continuation.yield(event) { throw CancellationError() }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }
}

struct DryTrialProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "eval-dry", capabilities: [.streaming, .multiTurn, .tools])
    let task: EvalTask

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "dry-\(request.messages.count)", model: request.model)
            let call: ToolCall?
            switch request.messages.last {
            case .user(let parts) where parts == [.text("Retry the same operation")]:
                call = .init(id: .init(rawValue: "retry-search"), name: EvalSearch.name,
                             argumentsJSON: #"{"query":"retry"}"#, completeness: .complete)
            case .user:
                call = .init(id: .init(rawValue: "first-search"), name: EvalSearch.name,
                             argumentsJSON: #"{"query":"fixture"}"#, completeness: .complete)
            case .tool(let result) where ["first-search", "retry-search"].contains(result.callID.rawValue):
                if task.scenario == "do_not_execute" { call = nil }
                else {
                    let id = task.group == "controlled_error" && result.callID.rawValue == "first-search" ? "X" : "A"
                    call = .init(id: .init(rawValue: "commit-\(id)-\(request.messages.count)"),
                                 name: EvalCommit.name,
                                 argumentsJSON: #"{"id":"\#(id)"}"#, completeness: .complete)
                }
            case .tool(let result) where result.isError &&
                result.callID.rawValue.hasPrefix("commit-X"):
                guard String(describing: result.content).contains("evidence_unavailable") else {
                    throw ModelProviderError(kind: .invalidRequest, message: "Missing linked rejection feedback.")
                }
                call = .init(id: .init(rawValue: "corrected-A"), name: EvalCommit.name,
                             argumentsJSON: #"{"id":"A"}"#, completeness: .complete)
            case .tool(let result) where !result.isError &&
                (result.callID.rawValue.hasPrefix("commit-A") || result.callID.rawValue == "corrected-A"):
                if task.scenario == "settled_model_failure" { throw EvalTrialError.dryRunFailure }
                call = nil
            default:
                throw ModelProviderError(kind: .invalidRequest, message: "Unexpected dry-run transcript.")
            }
            try emit(.responseStarted(info))
            if let call {
                try emit(.toolCallStarted(call.id, name: call.name))
                try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                try emit(.toolCallCompleted(call))
                try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
            } else {
                try emit(.textDelta("Done"))
                try emit(.responseCompleted(.init(info: info, content: [.text("Done")], stopReason: .endTurn)))
            }
        }
    }
}
