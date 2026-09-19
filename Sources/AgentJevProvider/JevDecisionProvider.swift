import AgentDecisions
import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// TypeSafe Jev System One adapter for the vendor-neutral decision contract.
/// It returns advice only and has no AgentCore or tool-execution authority.
public struct JevDecisionProvider: DecisionProvider, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Stable decision-provider identity.
    public let descriptor = DecisionProviderDescriptor(id: "jev")

    private let apiKey: String
    private let endpoint: URL
    private let model: String
    private let requestTimeout: Duration
    private let transport: any JevHTTPTransport

    public var description: String { "JevDecisionProvider" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["descriptor": descriptor]) }

    /// Configure a Jev adapter.
    ///
    /// - Parameters:
    ///   - apiKey: Bearer credential. It is never included in descriptions or errors.
    ///   - endpoint: HTTPS System One endpoint, or loopback HTTP for controlled tests.
    ///   - model: Jev model name or alias.
    ///   - requestTimeout: Per-attempt deadline cap. The adapter performs no hidden retry.
    public init(
        apiKey: String,
        endpoint: URL? = nil,
        model: String = "jev-latest",
        requestTimeout: Duration = .seconds(10)
    ) throws {
        try self.init(
            apiKey: apiKey,
            endpoint: endpoint,
            model: model,
            requestTimeout: requestTimeout,
            transport: URLSessionJevHTTPTransport()
        )
    }

    init(
        apiKey: String,
        endpoint: URL? = nil,
        model: String = "jev-latest",
        requestTimeout: Duration = .seconds(10),
        transport: any JevHTTPTransport
    ) throws {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !apiKey.contains("\r"), !apiKey.contains("\n"),
              !model.isEmpty, !model.contains("\r"), !model.contains("\n"),
              Self.seconds(requestTimeout) > 0,
              let endpoint = endpoint ?? URL(string: "https://api.typesafe.ai/v1/systemone") else {
            throw DecisionProviderError(
                kind: .invalidConfiguration,
                message: "Invalid Jev provider configuration."
            )
        }
        let host = endpoint.host?.lowercased() ?? ""
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard !host.isEmpty, endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
              endpoint.query == nil,
              endpoint.scheme?.lowercased() == "https" || (endpoint.scheme?.lowercased() == "http" && loopback) else {
            throw DecisionProviderError(
                kind: .invalidConfiguration,
                message: "The Jev endpoint must use HTTPS or local HTTP without embedded credentials."
            )
        }
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.model = model
        self.requestTimeout = requestTimeout
        self.transport = transport
    }

    /// Evaluate a typed decision request.
    ///
    /// Caller cancellation throws `CancellationError`. Transport and protocol
    /// failures use `DecisionProviderError` with sanitized diagnostics.
    public func decide(_ request: DecisionRequest) async throws -> DecisionResponse {
        try Task.checkCancellation()
        let body = try JevWire.encode(request: request, model: model)
        var mutableRequest = URLRequest(url: endpoint)
        mutableRequest.httpMethod = "POST"
        mutableRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        mutableRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        mutableRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        mutableRequest.httpBody = body
        let http = mutableRequest

        let providerDeadline = ContinuousClock.now.advanced(by: requestTimeout)
        let deadline = request.deadline.map { min($0, providerDeadline) } ?? providerDeadline
        let timeoutError = DecisionProviderError(
            kind: .deadlineExceeded,
            message: "The Jev decision request exceeded its deadline."
        )
        let response: JevHTTPResponse
        do {
            response = try await withOperationDeadline(deadline, timeoutError: timeoutError) {
                try await transport.send(http)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DecisionProviderError {
            throw error
        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled, Task.isCancelled {
                throw CancellationError()
            }
            if let urlError = error as? URLError, urlError.code == .timedOut {
                throw timeoutError
            }
            throw DecisionProviderError(kind: .transport, message: "The Jev HTTP request failed.")
        }

        try Task.checkCancellation()
        guard response.status == 200 else {
            throw JevWire.httpFailure(status: response.status, headers: response.headers)
        }
        return try JevWire.decode(response.body, for: request)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private enum JevWire {
    static func encode(request: DecisionRequest, model: String) throws -> Data {
        guard isContent(request.state, allowNull: false) else {
            throw DecisionProviderError(
                kind: .invalidRequest,
                message: "Jev state must be a string, object, or array."
            )
        }
        var questions: [String: JSONValue] = [:]
        for (name, question) in request.nouls {
            var object: [String: JSONValue] = ["type": .string("noul")]
            try add(question.instructions, named: "instructions", to: &object, allowNull: true)
            if question.trueCriteria != nil || question.falseCriteria != nil {
                var criteria: [String: JSONValue] = [:]
                try add(question.trueCriteria, named: "true", to: &criteria, allowNull: true)
                try add(question.falseCriteria, named: "false", to: &criteria, allowNull: true)
                object["criteria"] = .object(criteria)
            }
            questions[name] = .object(object)
        }
        for (name, question) in request.choices {
            var object: [String: JSONValue] = ["type": .string("choice")]
            try add(question.instructions, named: "instructions", to: &object, allowNull: true)
            var criteria: [String: JSONValue] = [:]
            for item in question.criteria {
                let value = item.description ?? .null
                guard isContent(value, allowNull: true) else { throw invalidContent() }
                criteria[item.name] = value
            }
            object["criteria"] = .object(criteria)
            questions[name] = .object(object)
        }
        for (name, question) in request.scores {
            var object: [String: JSONValue] = ["type": .string("score")]
            try add(question.instructions, named: "instructions", to: &object, allowNull: true)
            guard question.criteria.allSatisfy({ isContent($0, allowNull: false) }) else {
                throw invalidContent()
            }
            object["criteria"] = .array(question.criteria)
            questions[name] = .object(object)
        }
        do {
            return try JSONEncoder().encode(JSONValue.object([
                "state": request.state,
                "model": .string(model),
                "questions": .object(questions),
            ]))
        } catch {
            throw DecisionProviderError(kind: .invalidRequest, message: "The Jev decision request cannot be encoded.")
        }
    }

    static func decode(_ data: Data, for request: DecisionRequest) throws -> DecisionResponse {
        let wire: Response
        do { wire = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw invalidResponse() }
        guard isSafeMetadata(wire.model),
              wire.usage.inputTokens >= 0, wire.usage.outputTokens >= 0 else {
            throw invalidResponse()
        }
        let expected = Set(request.nouls.keys).union(request.choices.keys).union(request.scores.keys)
        guard Set(wire.answers.keys) == expected else { throw invalidResponse() }

        var nouls: [String: NoulDecision] = [:]
        for (name, question) in request.nouls {
            _ = question
            guard case .noul(let answer)? = wire.answers[name], isProbability(answer.noul) else {
                throw invalidResponse()
            }
            nouls[name] = .init(probability: answer.noul)
        }
        var choices: [String: ChoiceDecision] = [:]
        for (name, question) in request.choices {
            guard case .choice(let answer)? = wire.answers[name], isProbability(answer.confidence) else {
                throw invalidResponse()
            }
            let candidateNames = question.criteria.map(\.name)
            guard candidateNames.contains(answer.choice), Set(answer.probabilities.keys) == Set(candidateNames) else {
                throw invalidResponse()
            }
            let probabilities = try candidateNames.map { candidate -> DecisionChoiceProbability in
                guard let probability = answer.probabilities[candidate], isProbability(probability) else {
                    throw invalidResponse()
                }
                return .init(name: candidate, probability: probability)
            }
            choices[name] = .init(
                selected: answer.choice,
                confidence: answer.confidence,
                probabilities: probabilities
            )
        }
        var scores: [String: ScoreDecision] = [:]
        for (name, question) in request.scores {
            guard case .score(let answer)? = wire.answers[name],
                  answer.score.isFinite,
                  answer.score >= 0,
                  answer.score <= Double(question.criteria.count - 1),
                  isProbability(answer.confidence) else {
                throw invalidResponse()
            }
            let legend: [JSONValue] = try ordered(answer.legend, count: question.criteria.count)
            guard legend == question.criteria else { throw invalidResponse() }
            let probabilities: [Double] = try ordered(answer.probabilities, count: question.criteria.count)
            guard probabilities.allSatisfy(isProbability) else { throw invalidResponse() }
            scores[name] = .init(
                score: answer.score,
                confidence: answer.confidence,
                legend: legend,
                probabilities: probabilities
            )
        }
        return DecisionResponse(
            model: wire.model,
            nouls: nouls,
            choices: choices,
            scores: scores,
            usage: .init(inputTokens: wire.usage.inputTokens, outputTokens: wire.usage.outputTokens)
        )
    }

    static func httpFailure(status: Int, headers: [String: String]) -> DecisionProviderError {
        let kind: DecisionProviderError.Kind
        switch status {
        case 401: kind = .authentication
        case 403: kind = .permissionDenied
        case 408: kind = .transport
        case 429: kind = .rateLimited
        case 500...599: kind = .unavailable
        case 400...499: kind = .invalidRequest
        default: kind = .invalidResponse
        }
        return .init(
            kind: kind,
            message: "The Jev HTTP request failed (\(status)).",
            retryAfter: retryAfter(headers),
            requestID: safeRequestID(headers)
        )
    }

    private static func add(
        _ value: JSONValue?,
        named name: String,
        to object: inout [String: JSONValue],
        allowNull: Bool
    ) throws {
        guard let value else { return }
        guard isContent(value, allowNull: allowNull) else { throw invalidContent() }
        object[name] = value
    }

    private static func isContent(_ value: JSONValue, allowNull: Bool) -> Bool {
        switch value {
        case .string, .object, .array: true
        case .null: allowNull
        case .bool, .number: false
        }
    }

    private static func ordered<Value>(_ values: [String: Value], count: Int) throws -> [Value] {
        var ordered: [Value?] = Array(repeating: nil, count: count)
        for (rawIndex, value) in values {
            guard let index = Int(rawIndex), (0..<count).contains(index), ordered[index] == nil else {
                throw invalidResponse()
            }
            ordered[index] = value
        }
        guard ordered.allSatisfy({ $0 != nil }) else { throw invalidResponse() }
        return ordered.map { $0! }
    }

    private static func isProbability(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func retryAfter(_ headers: [String: String]) -> Duration? {
        if let raw = header("retry-after-ms", in: headers),
           let value = Double(raw), value.isFinite, value >= 0 {
            return .milliseconds(value)
        }
        guard let raw = header("retry-after", in: headers) else { return nil }
        if let value = Double(raw), value.isFinite, value >= 0 {
            return .seconds(value)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: raw) else { return nil }
        return .seconds(max(0, date.timeIntervalSinceNow))
    }

    private static func safeRequestID(_ headers: [String: String]) -> String? {
        guard let value = header("x-typesafe-request-id", in: headers), isSafeMetadata(value) else {
            return nil
        }
        return value
    }

    private static func isSafeMetadata(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func invalidContent() -> DecisionProviderError {
        .init(kind: .invalidRequest, message: "Jev instructions and criteria must use supported JSON content.")
    }

    private static func invalidResponse() -> DecisionProviderError {
        .init(kind: .invalidResponse, message: "The Jev response did not match the requested decision contract.")
    }

    private struct Response: Decodable {
        let model: String
        let answers: [String: Answer]
        let usage: Usage
    }

    private struct Usage: Decodable {
        let inputTokens: Int
        let outputTokens: Int

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    private enum Answer: Decodable {
        case noul(NoulAnswer)
        case choice(ChoiceAnswer)
        case score(ScoreAnswer)

        init(from decoder: any Decoder) throws {
            let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
            switch type {
            case "noul": self = .noul(try NoulAnswer(from: decoder))
            case "choice": self = .choice(try ChoiceAnswer(from: decoder))
            case "score": self = .score(try ScoreAnswer(from: decoder))
            default: throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported decision answer type."
            ))
            }
        }
    }

    private enum TypeKey: String, CodingKey { case type }
    private struct NoulAnswer: Decodable { let noul: Double }
    private struct ChoiceAnswer: Decodable {
        let choice: String
        let confidence: Double
        let probabilities: [String: Double]
    }
    private struct ScoreAnswer: Decodable {
        let score: Double
        let confidence: Double
        let legend: [String: JSONValue]
        let probabilities: [String: Double]
    }
}
