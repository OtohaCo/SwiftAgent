import AgentModels
import AgentProviders
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RequestEvidenceEntry: Equatable, Sendable, CustomStringConvertible {
    public let provider: QualificationProvider
    public let ordinal: Int
    public let origin: String
    public let model: String?
    public let messageCount: Int
    public let hasAssistantHistory: Bool
    public let hasToolCall: Bool
    public let hasToolResult: Bool
    public let hasBoundToolResult: Bool
    public let hasQualificationHistoryMarker: Bool
    public let hasProviderContinuation: Bool

    public var description: String {
        "request=\(ordinal) provider=\(provider.rawValue) origin=\(origin) model=\(model ?? "MISSING") "
            + "messages=\(messageCount) assistant_history=\(hasAssistantHistory) tool_call=\(hasToolCall) "
            + "tool_result=\(hasToolResult) bound_tool_result=\(hasBoundToolResult) "
            + "history_marker=\(hasQualificationHistoryMarker) continuation=\(hasProviderContinuation)"
    }
}

public struct ResponseEvidenceEntry: Equatable, Sendable, CustomStringConvertible {
    public let requestOrdinal: Int
    public let httpStatus: Int?
    public let eventTypes: [String]
    public let models: [String]
    public let responseStatuses: [String]
    public let itemTypes: [String]
    public let itemStatuses: [String]
    public let eventShapes: [String]
    public let missingSequenceEventTypes: [String]
    public let hasSequenceNumberForEveryEvent: Bool
    public let metadataTruncated: Bool

    public var description: String {
        "response_for_request=\(requestOrdinal) http_status=\(httpStatus.map(String.init) ?? "MISSING") "
            + "events=\(joined(eventTypes)) models=\(joined(models)) "
            + "response_statuses=\(joined(responseStatuses)) item_types=\(joined(itemTypes)) "
            + "item_statuses=\(joined(itemStatuses)) event_shapes=\(joined(eventShapes)) "
            + "missing_sequence=\(joined(missingSequenceEventTypes)) "
            + "sequence_complete=\(hasSequenceNumberForEveryEvent) "
            + "metadata_truncated=\(metadataTruncated)"
    }
}

public actor RequestEvidenceLedger {
    public private(set) var entries: [RequestEvidenceEntry] = []
    public private(set) var responses: [ResponseEvidenceEntry] = []
    private var observations: [Int: ResponseObservation] = [:]

    public init() {}

    @discardableResult
    func record(_ request: URLRequest, provider: QualificationProvider) -> Int {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let object = body as? [String: Any]
        let messages = (object?["input"] as? [Any]) ?? (object?["messages"] as? [Any]) ?? []
        let allObjects = flattenObjects(body)
        let toolCallIDs = Set(allObjects.compactMap(toolCallID))
        let toolResultIDs = Set(allObjects.compactMap(toolResultID))
        let entry = RequestEvidenceEntry(
            provider: provider,
            ordinal: entries.count + 1,
            origin: redactedRequestOrigin(request.url),
            model: object?["model"] as? String,
            messageCount: messages.count,
            hasAssistantHistory: allObjects.contains { $0["role"] as? String == "assistant" },
            hasToolCall: allObjects.contains {
                let type = $0["type"] as? String
                return type == "function_call" || type == "tool_use"
            },
            hasToolResult: allObjects.contains {
                let type = $0["type"] as? String
                return type == "function_call_output" || type == "tool_result"
            },
            hasBoundToolResult: !toolResultIDs.isEmpty && toolResultIDs.isSubset(of: toolCallIDs),
            hasQualificationHistoryMarker: containsQualificationHistoryMarker(body),
            hasProviderContinuation: allObjects.contains {
                let type = $0["type"] as? String
                return type == "reasoning" || type == "thinking" || $0["encrypted_content"] != nil
            }
        )
        entries.append(entry)
        observations[entry.ordinal] = .init()
        return entry.ordinal
    }

    func recordHTTPStatus(_ status: Int, requestOrdinal: Int) {
        observations[requestOrdinal]?.httpStatus = status
    }

    func recordResponseData(_ data: Data, requestOrdinal: Int) {
        guard var observation = observations[requestOrdinal], !observation.metadataTruncated else { return }
        guard observation.data.count + data.count <= ResponseObservation.maximumBytes else {
            observation.data.removeAll(keepingCapacity: false)
            observation.metadataTruncated = true
            observations[requestOrdinal] = observation
            return
        }
        observation.data.append(data)
        observations[requestOrdinal] = observation
    }

    func finishResponse(requestOrdinal: Int) {
        guard let observation = observations.removeValue(forKey: requestOrdinal) else { return }
        responses.append(observation.result(requestOrdinal: requestOrdinal))
    }
}

private func toolCallID(_ object: [String: Any]) -> String? {
    switch object["type"] as? String {
    case "function_call": return object["call_id"] as? String
    case "tool_use": return object["id"] as? String
    default: return nil
    }
}

private func toolResultID(_ object: [String: Any]) -> String? {
    switch object["type"] as? String {
    case "function_call_output": return object["call_id"] as? String
    case "tool_result": return object["tool_use_id"] as? String
    default: return nil
    }
}

private func containsQualificationHistoryMarker(_ value: Any?) -> Bool {
    let markers = ["BLUE-17", "RESTART-TOOL-17"]
    if let text = value as? String { return markers.contains(where: text.contains) }
    if let object = value as? [String: Any] {
        return object.values.contains(where: containsQualificationHistoryMarker)
    }
    if let array = value as? [Any] {
        return array.contains(where: containsQualificationHistoryMarker)
    }
    return false
}

public struct BudgetedProviderHTTPTransport: ProviderHTTPTransport {
    private let provider: QualificationProvider
    private let budget: LiveRequestBudget
    private let evidence: RequestEvidenceLedger
    private let base: any ProviderHTTPTransport

    public init(
        provider: QualificationProvider,
        budget: LiveRequestBudget,
        evidence: RequestEvidenceLedger,
        base: any ProviderHTTPTransport = URLSessionProviderHTTPTransport()
    ) {
        self.provider = provider
        self.budget = budget
        self.evidence = evidence
        self.base = base
    }

    public func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                var requestOrdinal: Int?
                do {
                    try await budget.reserve(provider)
                    requestOrdinal = await evidence.record(request, provider: provider)
                    for try await event in base.stream(request) {
                        try Task.checkCancellation()
                        if let requestOrdinal {
                            switch event {
                            case .response(let status, _):
                                await evidence.recordHTTPStatus(status, requestOrdinal: requestOrdinal)
                            case .data(let data):
                                await evidence.recordResponseData(data, requestOrdinal: requestOrdinal)
                            }
                        }
                        if case .terminated = continuation.yield(event) { throw CancellationError() }
                    }
                    try Task.checkCancellation()
                    if let requestOrdinal { await evidence.finishResponse(requestOrdinal: requestOrdinal) }
                    continuation.finish()
                } catch {
                    if let requestOrdinal { await evidence.finishResponse(requestOrdinal: requestOrdinal) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }
}

private struct ResponseObservation {
    static let maximumBytes = 1_048_576

    var httpStatus: Int?
    var data = Data()
    var metadataTruncated = false

    func result(requestOrdinal: Int) -> ResponseEvidenceEntry {
        let metadata = metadataTruncated ? ResponseMetadata() : parseResponseMetadata(data)
        return .init(
            requestOrdinal: requestOrdinal,
            httpStatus: httpStatus,
            eventTypes: metadata.eventTypes,
            models: metadata.models,
            responseStatuses: metadata.responseStatuses,
            itemTypes: metadata.itemTypes,
            itemStatuses: metadata.itemStatuses,
            eventShapes: metadata.eventShapes,
            missingSequenceEventTypes: metadata.missingSequenceEventTypes,
            hasSequenceNumberForEveryEvent: metadata.eventCount > 0
                && metadata.sequenceCount == metadata.eventCount,
            metadataTruncated: metadataTruncated
        )
    }
}

private struct ResponseMetadata {
    var eventTypes: [String] = []
    var models: [String] = []
    var responseStatuses: [String] = []
    var itemTypes: [String] = []
    var itemStatuses: [String] = []
    var eventShapes: [String] = []
    var missingSequenceEventTypes: [String] = []
    var eventCount = 0
    var sequenceCount = 0
}

private func parseResponseMetadata(_ data: Data) -> ResponseMetadata {
    guard let source = String(data: data, encoding: .utf8) else { return .init() }
    var result = ResponseMetadata()
    let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
    for frame in normalized.components(separatedBy: "\n\n") {
        let lines = frame.components(separatedBy: .newlines)
        let payload = lines.compactMap { line -> String? in
            guard line.hasPrefix("data:") else { return nil }
            return String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
        guard !payload.isEmpty, payload != "[DONE]",
              let value = try? JSONSerialization.jsonObject(with: Data(payload.utf8)),
              let object = value as? [String: Any], let type = object["type"] as? String else { continue }
        appendUnique(type, to: &result.eventTypes)
        result.eventCount += 1
        if object["sequence_number"] is NSNumber { result.sequenceCount += 1 }
        else { appendUnique(type, to: &result.missingSequenceEventTypes) }
        appendUnique(eventShape(type: type, object: object), to: &result.eventShapes)
        if let response = object["response"] as? [String: Any] {
            appendString(response["model"], to: &result.models)
            appendString(response["status"], to: &result.responseStatuses)
            if let output = response["output"] as? [[String: Any]] {
                for item in output { appendItemMetadata(item, to: &result) }
            }
        }
        if let item = object["item"] as? [String: Any] {
            appendItemMetadata(item, to: &result)
        }
    }
    return result
}

private func eventShape(type: String, object: [String: Any]) -> String {
    var fields: [String] = []
    if object["sequence_number"] is NSNumber { fields.append("sequence") }
    if let value = object["output_index"] as? NSNumber { fields.append("index=\(value.intValue)") }
    if let value = object["content_index"] as? NSNumber { fields.append("content=\(value.intValue)") }
    if let item = object["item"] as? [String: Any] {
        if let value = item["type"] as? String { fields.append("item=\(value)") }
        if let value = item["status"] as? String { fields.append("item_status=\(value)") }
    }
    if let response = object["response"] as? [String: Any],
       let output = response["output"] as? [Any] {
        fields.append("output_count=\(output.count)")
    }
    return fields.isEmpty ? type : "\(type)[\(fields.joined(separator: ","))]"
}

private func appendItemMetadata(_ item: [String: Any], to metadata: inout ResponseMetadata) {
    appendString(item["type"], to: &metadata.itemTypes)
    appendString(item["status"], to: &metadata.itemStatuses)
}

private func appendString(_ value: Any?, to values: inout [String]) {
    guard let value = value as? String else { return }
    appendUnique(value, to: &values)
}

private func appendUnique(_ value: String, to values: inout [String]) {
    if !values.contains(value) { values.append(value) }
}

private func joined(_ values: [String]) -> String {
    values.isEmpty ? "NONE" : values.joined(separator: ",")
}

private func flattenObjects(_ value: Any?) -> [[String: Any]] {
    guard let value else { return [] }
    if let object = value as? [String: Any] {
        return [object] + object.values.flatMap(flattenObjects)
    }
    if let array = value as? [Any] { return array.flatMap(flattenObjects) }
    return []
}

private func redactedRequestOrigin(_ url: URL?) -> String {
    guard let url, let scheme = url.scheme, let host = url.host else { return "INVALID" }
    if let port = url.port, port != 80, port != 443 { return "\(scheme)://\(host):\(port)" }
    return "\(scheme)://\(host)"
}
