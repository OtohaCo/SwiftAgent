import AgentModels
import Foundation
import Testing

struct ModelContinuationTests {
    @Test func terminalCannotReplaceOpaqueResponseOrModelIdentity() throws {
        let model = ModelID(provider: "fixture", name: "e\u{301}")
        let info = ResponseInfo(id: "e\u{301}", model: model)
        let state = ModelProviderContinuation(model: model, format: "v1", payload: Data([1]))
        for replacement in [ResponseInfo(id: "\u{e9}", model: model),
                            .init(id: info.id, model: .init(provider: "fixture", name: "\u{e9}"))] {
            var stream = ModelEventAccumulator()
            try stream.append(.responseStarted(info))
            try stream.append(.providerContinuation(state))
            #expect(throws: ModelStreamError.responseMismatch) {
                try stream.append(.responseCompleted(.init(info: replacement, content: [.providerContinuation(state)], stopReason: .endTurn)))
            }
        }
        #expect(Set([model, ModelID(provider: "fixture", name: "\u{e9}")]).count == 2)
        #expect(Set([info, ResponseInfo(id: "\u{e9}", model: model)]).count == 2)
    }

    @Test func invalidOwnershipOrEmptyStateFailsClosed() throws {
        let model = ModelID(provider: "fixture", name: "test")
        let values = [
            ModelProviderContinuation(model: .init(provider: "other", name: "test"), format: "v1", payload: Data([1])),
            .init(model: .init(provider: "fixture", name: "other"), format: "v1", payload: Data([1])),
            .init(model: model, format: " \n", payload: Data([1])),
            .init(model: model, format: "v1", payload: Data()),
        ]
        for value in values {
            var stream = ModelEventAccumulator()
            try stream.append(.responseStarted(.init(id: "response", model: model)))
            #expect(throws: ModelStreamError.invalidContinuation) { try stream.append(.providerContinuation(value)) }
            #expect(throws: ModelStreamError.invalidContinuation) { try stream.finish() }
        }
    }

    @Test func ownershipFormatAndTerminalPayloadUseExactIdentity() throws {
        let model = ModelID(provider: "fixture", name: "e\u{301}")
        let first = ModelProviderContinuation(model: model, format: "e\u{301}", payload: Data([1]))
        let changedFormat = ModelProviderContinuation(model: model, format: "\u{e9}", payload: Data([1]))
        let changedOwner = ModelProviderContinuation(model: .init(provider: "fixture", name: "\u{e9}"), format: first.format, payload: first.payload)
        #expect(Set([first, changedFormat, changedOwner]).count == 3)
        var stream = ModelEventAccumulator()
        let info = ResponseInfo(id: "response", model: model)
        try stream.append(.responseStarted(info))
        try stream.append(.providerContinuation(first))
        #expect(throws: ModelStreamError.responseMismatch) {
            try stream.append(.responseCompleted(.init(info: info, content: [.providerContinuation(changedFormat)], stopReason: .endTurn)))
        }
        var changedBytes = ModelEventAccumulator()
        try changedBytes.append(.responseStarted(info))
        try changedBytes.append(.providerContinuation(first))
        #expect(throws: ModelStreamError.responseMismatch) {
            try changedBytes.append(.responseCompleted(.init(info: info, content: [
                .providerContinuation(.init(model: model, format: first.format, payload: Data([2]))),
            ], stopReason: .endTurn)))
        }
        var other = ModelEventAccumulator()
        try other.append(.responseStarted(info))
        #expect(throws: ModelStreamError.invalidContinuation) { try other.append(.providerContinuation(changedOwner)) }
    }

    @Test func opaqueBytesRoundTripAndSealAlongsideVisibleContent() throws {
        let model = ModelID(provider: "fixture", name: "test")
        let value = ModelProviderContinuation(model: model, format: "fixture.v1", payload: Data([0, 255, 1]))
        let info = ResponseInfo(id: "response", model: model)
        var accumulator = ModelEventAccumulator()
        try accumulator.append(.responseStarted(info))
        try accumulator.append(.textDelta("Answer"))
        try accumulator.append(.providerContinuation(value))
        let expected = ModelResponse(info: info, content: [.text("Answer"), .providerContinuation(value)], stopReason: .endTurn)
        try accumulator.append(.responseCompleted(expected))
        #expect(try accumulator.finish() == expected)
        #expect(try JSONDecoder().decode(ModelResponse.self, from: JSONEncoder().encode(expected)) == expected)
    }
}
