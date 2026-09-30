import AgentDecisions
import AgentJevProvider
import AgentModels
import Foundation

private struct Input: Decodable {
    struct Candidate: Decodable { let id: String; let description: String }
    let mode: String
    let endpoint: String
    let model: String
    let keyEnvironment: String?
    let timeoutSeconds: Double
    let state: String
    let candidates: [Candidate]
    let instructions: String
    let promptVersion: String
}

/// Public package consumer. One process owns exactly one real SDK request.
/// No AgentCore, executor, approval conversion, retries or vendor selection.
@main struct DecisionEvalTrial {
    static func main() async {
        var output: [String: Any] = ["status": "invalid_configuration"]
        do {
            let data = try FileHandle.standardInput.read(upToCount: 64 * 1024 + 1) ?? Data()
            guard data.count <= 64 * 1024 else { throw InvalidInput() }
            let input = try JSONDecoder().decode(Input.self, from: data)
            guard ["fixture", "live"].contains(input.mode),
                  let endpoint = URL(string: input.endpoint), endpoint.host != nil,
                  input.timeoutSeconds.isFinite, input.timeoutSeconds > 0, input.timeoutSeconds <= 60,
                  input.state.utf8.count <= 8192, (2...20).contains(input.candidates.count),
                  input.instructions.utf8.count <= 8192,
                  isLabel(input.model), isLabel(input.promptVersion) else { throw InvalidInput() }
            if input.mode == "fixture" {
                guard endpoint.scheme == "http", ["127.0.0.1", "localhost", "::1", "[::1]"].contains(endpoint.host!) else {
                    throw InvalidInput()
                }
            } else if endpoint.scheme != "https" { throw InvalidInput() }
            let key: String
            if input.mode == "fixture" {
                key = "decision-evaluation-fixture-not-a-credential"
            } else {
                guard let name = input.keyEnvironment, isLabel(name),
                      let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { throw InvalidInput() }
                key = value
            }
            let candidates = try input.candidates.map { candidate in
                guard isLabel(candidate.id), candidate.description.utf8.count <= 2048 else { throw InvalidInput() }
                return DecisionChoiceCriterion(name: candidate.id, description: .string(candidate.description))
            }
            // Jev represents criteria as an object: never claim its key order is
            // the SDK array order. Render display order in the versioned prompt.
            let ordered = input.candidates.enumerated().map { "\($0.offset + 1). \($0.element.id)" }.joined(separator: "\n")
            let request = try DecisionRequest(
                state: .string(input.state),
                choices: ["route": try .init(
                    instructions: .string(input.instructions + "\nCandidate display order (" + input.promptVersion + "):\n" + ordered),
                    criteria: candidates
                )],
                deadline: ContinuousClock.now.advanced(by: .seconds(input.timeoutSeconds))
            )
            let provider: any DecisionProvider = try JevDecisionProvider(
                apiKey: key, endpoint: endpoint, model: input.model, requestTimeout: .seconds(input.timeoutSeconds)
            )
            let dispatch = ContinuousClock.now
            let response = try await provider.decide(request)
            try Task.checkCancellation()
            guard let answer = response.choices["route"] else { throw InvalidInput() }
            let elapsed = dispatch.duration(to: .now).components
            let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            output = ["status": "success", "selected": answer.selected, "confidence": answer.confidence,
                      "probabilities": Dictionary(uniqueKeysWithValues: answer.probabilities.map { ($0.name, $0.probability) }),
                      "latencyMs": milliseconds, "providerAdapter": "jev", "protocolVersion": "systemone-existing-sdk",
                      "valueSource": "provider_reported", "actualModel": isLabel(response.model) && !response.model.contains(key)
                        ? response.model : "redacted", "actualModelRedacted": !isLabel(response.model) || response.model.contains(key)]
            if let usage = response.usage {
                output["usage"] = ["inputTokens": usage.inputTokens, "outputTokens": usage.outputTokens]
            }
        } catch is CancellationError {
            output = ["status": "cancelled"]
        } catch let error as DecisionProviderError {
            // No requestID, error text, body, endpoint, key or arbitrary extension.
            let allowed = ["invalid_configuration", "authentication", "permission_denied", "invalid_request",
                           "rate_limited", "unavailable", "transport", "invalid_response", "deadline_exceeded"]
            output = ["status": allowed.contains(error.kind.rawValue) ? error.kind.rawValue : "invalid_response"]
        } catch {
            output = ["status": "invalid_configuration"]
        }
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
    private struct InvalidInput: Error {}
    private static func isLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 96 && value.unicodeScalars.allSatisfy {
            ("a"..."z").contains(String($0)) || ("A"..."Z").contains(String($0)) ||
            ("0"..."9").contains(String($0)) || "_.-".unicodeScalars.contains($0)
        }
    }
}
