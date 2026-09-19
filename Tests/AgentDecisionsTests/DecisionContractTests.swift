import AgentDecisions
import AgentModels
import Foundation
import Testing

struct DecisionContractTests {
    @Test func buildsTypedNoulChoiceAndScoreRequest() throws {
        let request = try DecisionRequest(
            state: .object(["message": .string("Please help with this charge")]),
            nouls: ["billing": .init(instructions: .string("Is this about billing?"))],
            choices: ["tone": try .init(
                instructions: .string("What is the tone?"),
                criteria: [
                    .init(name: "calm", description: .string("Neutral or polite")),
                    .init(name: "angry", description: .string("Upset or hostile")),
                ]
            )],
            scores: ["urgency": try .init(
                instructions: .string("How urgent is it?"),
                criteria: [.string("Can wait"), .string("Needs attention today")]
            )]
        )

        #expect(request.questionCount == 3)
        #expect(request.choices["tone"]?.criteria.map(\.name) == ["calm", "angry"])
        #expect(request.scores["urgency"]?.criteria.count == 2)
    }

    @Test func requestRejectsMissingDuplicateAndInvalidQuestionIdentities() throws {
        #expect(throws: DecisionValidationError.self) {
            _ = try DecisionRequest(state: .string("x"))
        }
        #expect(throws: DecisionValidationError.self) {
            _ = try DecisionRequest(
                state: .string("x"),
                nouls: ["same": .init()],
                choices: ["same": try .init(criteria: [.init(name: "a")])]
            )
        }
        #expect(throws: DecisionValidationError.self) {
            _ = try DecisionRequest(state: .string("x"), nouls: ["   ": .init()])
        }
        #expect(throws: DecisionValidationError.self) {
            _ = try DecisionRequest(state: .string("x"), nouls: ["line\nbreak": .init()])
        }
    }

    @Test func choiceRejectsEmptyAndDuplicateCandidateIdentities() {
        #expect(throws: DecisionValidationError.self) {
            _ = try ChoiceQuestion(criteria: [])
        }
        #expect(throws: DecisionValidationError.self) {
            _ = try ChoiceQuestion(criteria: [.init(name: "yes"), .init(name: "yes")])
        }
        #expect(throws: DecisionValidationError.self) {
            _ = try ChoiceQuestion(criteria: [.init(name: "\n")])
        }
        #expect(throws: DecisionValidationError.self) {
            _ = try ChoiceQuestion(criteria: [.init(name: "yes\u{0000}no")])
        }
    }

    @Test func scoreRequiresAtLeastTwoOrderedLevels() {
        #expect(throws: DecisionValidationError.self) {
            _ = try ScoreQuestion(criteria: [])
        }
        #expect(throws: DecisionValidationError.self) {
            _ = try ScoreQuestion(criteria: [.string("only")])
        }
    }

    @Test func codableCannotBypassQuestionValidation() throws {
        let decoder = JSONDecoder()
        #expect(throws: DecisionValidationError.self) {
            _ = try decoder.decode(ChoiceQuestion.self, from: Data(#"{"criteria":[]}"#.utf8))
        }
        #expect(throws: DecisionValidationError.self) {
            _ = try decoder.decode(
                ChoiceQuestion.self,
                from: Data(#"{"criteria":[{"name":"same"},{"name":"same"}]}"#.utf8)
            )
        }
        #expect(throws: DecisionValidationError.self) {
            _ = try decoder.decode(ScoreQuestion.self, from: Data(#"{"criteria":["only"]}"#.utf8))
        }
    }

    @Test func validatedQuestionsRoundTripThroughCodable() throws {
        let choice = try ChoiceQuestion(
            instructions: .string("Choose a route"),
            criteria: [.init(name: "support"), .init(name: "billing")]
        )
        let score = try ScoreQuestion(
            instructions: .string("Rate urgency"),
            criteria: [.string("Can wait"), .string("Today")]
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        #expect(try decoder.decode(ChoiceQuestion.self, from: encoder.encode(choice)) == choice)
        #expect(try decoder.decode(ScoreQuestion.self, from: encoder.encode(score)) == score)
    }

    @Test func typedResponseValuesRoundTripWithoutVendorDTOs() throws {
        let response = DecisionResponse(
            model: "jev-2026-09-15",
            nouls: ["billing": .init(probability: 0.98)],
            choices: ["tone": .init(
                selected: "calm", confidence: 0.9,
                probabilities: [.init(name: "calm", probability: 0.9), .init(name: "angry", probability: 0.1)]
            )],
            scores: ["urgency": .init(
                score: 1.7, confidence: 0.8,
                legend: [.string("Can wait"), .string("Today")], probabilities: [0.1, 0.9]
            )],
            usage: .init(inputTokens: 120, outputTokens: 12)
        )
        let data = try JSONEncoder().encode(response)
        #expect(try JSONDecoder().decode(DecisionResponse.self, from: data) == response)
    }

    @Test func providerContractHasNoExecutionAuthority() async throws {
        let provider: any DecisionProvider = FixtureDecisionProvider()
        let response = try await provider.decide(try .init(
            state: .string("state"), nouls: ["answer": .init()]
        ))
        #expect(response.nouls["answer"]?.probability == 0.75)
    }
}

private struct FixtureDecisionProvider: DecisionProvider {
    let descriptor = DecisionProviderDescriptor(id: "fixture")

    func decide(_ request: DecisionRequest) async throws -> DecisionResponse {
        DecisionResponse(model: "fixture", nouls: ["answer": .init(probability: 0.75)])
    }
}
