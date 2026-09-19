import AgentDecisions
import AgentJevProvider
import AgentModels
import Foundation

@main
struct JevDecisionExample {
    static func main() async throws {
        let request = try DecisionRequest(
            state: .object([
                "message": .string("I was charged twice and need help today."),
            ]),
            nouls: [
                "billing": .init(instructions: .string("Is this about billing?")),
            ],
            choices: [
                "route": try .init(
                    instructions: .string("Which team should review this?"),
                    criteria: [
                        .init(name: "support", description: .string("General product support")),
                        .init(name: "billing", description: .string("Payments and charges")),
                    ]
                ),
            ],
            scores: [
                "urgency": try .init(
                    instructions: .string("How soon should a person review this?"),
                    criteria: [.string("Can wait"), .string("Today")]
                ),
            ]
        )

        guard let provider = try makeProvider() else { return }
        let response = try await provider.decide(request)
        let proposal = ReviewProposal(
            queue: response.choices["route"]?.selected ?? "manual-review",
            urgent: (response.scores["urgency"]?.score ?? 0) >= 0.5,
            requiresBillingReview: (response.nouls["billing"]?.probability ?? 0) >= 0.5
        )

        print("model=\(response.model)")
        print("proposal queue=\(proposal.queue) urgent=\(proposal.urgent) billing=\(proposal.requiresBillingReview)")
        print("This proposal is not authorization and does not execute a tool.")
    }

    private static func makeProvider() throws -> (any DecisionProvider)? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SWIFT_AGENT_JEV_LIVE"] == "1" else {
            return FixtureDecisionProvider()
        }
        guard let apiKey = environment["TYPESAFE_API_KEY"], !apiKey.isEmpty else {
            FileHandle.standardError.write(Data(
                "SWIFT_AGENT_JEV_LIVE=1 requires TYPESAFE_API_KEY. The fixture example needs no credentials.\n".utf8
            ))
            return nil
        }
        return try JevDecisionProvider(
            apiKey: apiKey,
            model: environment["TYPESAFE_MODEL"] ?? "jev-latest"
        )
    }
}

private struct ReviewProposal: Sendable {
    let queue: String
    let urgent: Bool
    let requiresBillingReview: Bool
}

private struct FixtureDecisionProvider: DecisionProvider {
    let descriptor = DecisionProviderDescriptor(id: "fixture")

    func decide(_ request: DecisionRequest) async throws -> DecisionResponse {
        DecisionResponse(
            model: "fixture",
            nouls: ["billing": .init(probability: 0.98)],
            choices: ["route": .init(
                selected: "billing",
                confidence: 0.95,
                probabilities: [
                    .init(name: "support", probability: 0.05),
                    .init(name: "billing", probability: 0.95),
                ]
            )],
            scores: ["urgency": .init(
                score: 0.9,
                confidence: 0.9,
                legend: [.string("Can wait"), .string("Today")],
                probabilities: [0.1, 0.9]
            )],
            usage: .init(inputTokens: 18, outputTokens: 6)
        )
    }
}
