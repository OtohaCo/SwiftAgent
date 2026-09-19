import AgentModels
import Foundation

/// Construction failure for a vendor-neutral decision request.
public struct DecisionValidationError: Error, Equatable, Sendable {
    /// Extensible machine-readable validation category.
    public struct Kind: RawRepresentable, Hashable, Sendable, Codable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let emptyQuestions = Self(rawValue: "empty_questions")
        public static let invalidQuestionName = Self(rawValue: "invalid_question_name")
        public static let duplicateQuestionName = Self(rawValue: "duplicate_question_name")
        public static let emptyChoiceCriteria = Self(rawValue: "empty_choice_criteria")
        public static let invalidChoiceName = Self(rawValue: "invalid_choice_name")
        public static let duplicateChoiceName = Self(rawValue: "duplicate_choice_name")
        public static let insufficientScoreCriteria = Self(rawValue: "insufficient_score_criteria")

        public init(from decoder: any Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// Stable validation category.
    public let kind: Kind
    /// Question or candidate identity associated with the failure, when applicable.
    public let field: String?

    public init(kind: Kind, field: String? = nil) {
        self.kind = kind
        self.field = field
    }
}

/// A yes/no question whose result is the probability of yes or true.
public struct NoulQuestion: Hashable, Sendable, Codable {
    /// Optional question or statement expressed as JSON content.
    public let instructions: JSONValue?
    /// Optional description of what counts as yes or true.
    public let trueCriteria: JSONValue?
    /// Optional description of what counts as no or false.
    public let falseCriteria: JSONValue?

    public init(
        instructions: JSONValue? = nil,
        trueCriteria: JSONValue? = nil,
        falseCriteria: JSONValue? = nil
    ) {
        self.instructions = instructions
        self.trueCriteria = trueCriteria
        self.falseCriteria = falseCriteria
    }
}

/// One named candidate in a Choice question.
public struct DecisionChoiceCriterion: Hashable, Sendable, Codable {
    /// Exact, case-sensitive candidate identity returned by a provider.
    public let name: String
    /// Optional description of when the candidate applies.
    public let description: JSONValue?

    public init(name: String, description: JSONValue? = nil) {
        self.name = name
        self.description = description
    }
}

/// A question that selects one of a set of named candidates.
public struct ChoiceQuestion: Hashable, Sendable, Codable {
    /// Optional selection instructions expressed as JSON content.
    public let instructions: JSONValue?
    /// Ordered candidates. Names must be nonempty, control-free, and unique.
    public let criteria: [DecisionChoiceCriterion]

    public init(
        instructions: JSONValue? = nil,
        criteria: [DecisionChoiceCriterion]
    ) throws {
        guard !criteria.isEmpty else {
            throw DecisionValidationError(kind: .emptyChoiceCriteria)
        }
        var names = Set<String>()
        for criterion in criteria {
            guard isValidDecisionIdentity(criterion.name) else {
                throw DecisionValidationError(kind: .invalidChoiceName, field: criterion.name)
            }
            guard names.insert(criterion.name).inserted else {
                throw DecisionValidationError(kind: .duplicateChoiceName, field: criterion.name)
            }
        }
        self.instructions = instructions
        self.criteria = criteria
    }

    private enum CodingKeys: String, CodingKey { case instructions, criteria }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            instructions: container.decodeIfPresent(JSONValue.self, forKey: .instructions),
            criteria: container.decode([DecisionChoiceCriterion].self, forKey: .criteria)
        )
    }
}

/// A question that rates state against an ordered zero-based rubric.
public struct ScoreQuestion: Hashable, Sendable, Codable {
    /// Optional rating instructions expressed as JSON content.
    public let instructions: JSONValue?
    /// Ordered rubric levels. At least two levels are required.
    public let criteria: [JSONValue]

    public init(instructions: JSONValue? = nil, criteria: [JSONValue]) throws {
        guard criteria.count >= 2 else {
            throw DecisionValidationError(kind: .insufficientScoreCriteria)
        }
        self.instructions = instructions
        self.criteria = criteria
    }

    private enum CodingKeys: String, CodingKey { case instructions, criteria }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            instructions: container.decodeIfPresent(JSONValue.self, forKey: .instructions),
            criteria: container.decode([JSONValue].self, forKey: .criteria)
        )
    }
}

/// Vendor-neutral state and typed questions for one decision request.
public struct DecisionRequest: Sendable, Equatable {
    /// State evaluated by every question. Individual providers may support a subset of JSON forms.
    public let state: JSONValue
    /// Named yes/no questions.
    public let nouls: [String: NoulQuestion]
    /// Named candidate-selection questions.
    public let choices: [String: ChoiceQuestion]
    /// Named ordered-rubric questions.
    public let scores: [String: ScoreQuestion]
    /// Optional absolute deadline owned by the Host operation.
    public let deadline: ContinuousClock.Instant?

    /// Total questions across all three categories.
    public var questionCount: Int { nouls.count + choices.count + scores.count }

    public init(
        state: JSONValue,
        nouls: [String: NoulQuestion] = [:],
        choices: [String: ChoiceQuestion] = [:],
        scores: [String: ScoreQuestion] = [:],
        deadline: ContinuousClock.Instant? = nil
    ) throws {
        guard !nouls.isEmpty || !choices.isEmpty || !scores.isEmpty else {
            throw DecisionValidationError(kind: .emptyQuestions)
        }
        var names = Set<String>()
        for name in nouls.keys.sorted() + choices.keys.sorted() + scores.keys.sorted() {
            guard isValidDecisionIdentity(name) else {
                throw DecisionValidationError(kind: .invalidQuestionName, field: name)
            }
            guard names.insert(name).inserted else {
                throw DecisionValidationError(kind: .duplicateQuestionName, field: name)
            }
        }
        self.state = state
        self.nouls = nouls
        self.choices = choices
        self.scores = scores
        self.deadline = deadline
    }
}

private func isValidDecisionIdentity(_ value: String) -> Bool {
    value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        && !value.isEmpty
        && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
}

/// Probability of yes or true for a Noul question.
public struct NoulDecision: Hashable, Sendable, Codable {
    /// Provider-reported probability in `0...1`.
    public let probability: Double
    public init(probability: Double) { self.probability = probability }
}

/// One named probability in a Choice result.
public struct DecisionChoiceProbability: Hashable, Sendable, Codable {
    /// Candidate identity from the request.
    public let name: String
    /// Provider-reported probability in `0...1`.
    public let probability: Double

    public init(name: String, probability: Double) {
        self.name = name
        self.probability = probability
    }
}

/// Selected candidate and probability distribution for a Choice question.
public struct ChoiceDecision: Hashable, Sendable, Codable {
    /// Exact identity of the selected request candidate.
    public let selected: String
    /// Provider-reported confidence in `0...1`.
    public let confidence: Double
    /// One probability per request candidate, in request order when the adapter can preserve it.
    public let probabilities: [DecisionChoiceProbability]

    public init(selected: String, confidence: Double, probabilities: [DecisionChoiceProbability]) {
        self.selected = selected
        self.confidence = confidence
        self.probabilities = probabilities
    }
}

/// Expected score and probability distribution for an ordered rubric.
public struct ScoreDecision: Hashable, Sendable, Codable {
    /// Probability-weighted expected score between the first and last rubric indices.
    public let score: Double
    /// Provider-reported confidence in `0...1`.
    public let confidence: Double
    /// Rubric levels in request order.
    public let legend: [JSONValue]
    /// One probability per rubric level, in the same order as `legend`.
    public let probabilities: [Double]

    public init(score: Double, confidence: Double, legend: [JSONValue], probabilities: [Double]) {
        self.score = score
        self.confidence = confidence
        self.legend = legend
        self.probabilities = probabilities
    }
}

/// Provider-reported token usage for one decision request.
public struct DecisionUsage: Hashable, Sendable, Codable {
    /// Number of input tokens reported by the provider.
    public let inputTokens: Int
    /// Number of output tokens reported by the provider.
    public let outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Typed answers and metadata returned by a decision provider.
public struct DecisionResponse: Hashable, Sendable, Codable {
    /// Actual model identity reported by the provider; aliases may resolve to another value.
    public let model: String
    /// Noul answers keyed by request question identity.
    public let nouls: [String: NoulDecision]
    /// Choice answers keyed by request question identity.
    public let choices: [String: ChoiceDecision]
    /// Score answers keyed by request question identity.
    public let scores: [String: ScoreDecision]
    /// Usage when the provider reports it.
    public let usage: DecisionUsage?

    public init(
        model: String,
        nouls: [String: NoulDecision] = [:],
        choices: [String: ChoiceDecision] = [:],
        scores: [String: ScoreDecision] = [:],
        usage: DecisionUsage? = nil
    ) {
        self.model = model
        self.nouls = nouls
        self.choices = choices
        self.scores = scores
        self.usage = usage
    }
}
