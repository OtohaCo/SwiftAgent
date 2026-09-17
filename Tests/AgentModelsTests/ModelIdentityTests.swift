import AgentModels
import Testing

struct ModelIdentityTests {
    private let info = ResponseInfo(id: "identity", model: .init(provider: "fixture", name: "test"))
    private let nfd = "cafe\u{301}"
    private let nfc = "caf\u{e9}"

    @Test func callIDsAndCallsPreserveByteDistinctValuesInSetsAndDictionaries() {
        let a = ToolCallID(rawValue: nfd), b = ToolCallID(rawValue: nfc)
        #expect(a != b)
        #expect(Set([a, b]).count == 2)
        var values = [a: 1]
        values[b] = 2
        #expect(values[a] == 1)
        #expect(values[b] == 2)
        let calls = [
            ToolCall(id: a, name: nfd, argumentsJSON: nfd),
            ToolCall(id: b, name: nfd, argumentsJSON: nfd),
            ToolCall(id: a, name: nfc, argumentsJSON: nfd),
            ToolCall(id: a, name: nfd, argumentsJSON: nfc),
        ]
        #expect(Set(calls).count == 4)
    }

    @Test func streamRejectsByteChangesAtEveryToolBoundary() throws {
        let original = ToolCall(id: .init(rawValue: nfd), name: nfd,
                                argumentsJSON: "{\"path\":\"\(nfd)\"}", completeness: .complete)
        let changed = [
            ToolCall(id: .init(rawValue: nfc), name: original.name, argumentsJSON: original.argumentsJSON, completeness: .complete),
            ToolCall(id: original.id, name: nfc, argumentsJSON: original.argumentsJSON, completeness: .complete),
            ToolCall(id: original.id, name: original.name, argumentsJSON: "{\"path\":\"\(nfc)\"}", completeness: .complete),
        ]
        for (index, replacement) in changed.enumerated() {
            var atCompletion = try prefix(original)
            #expect(throws: index == 0 ? ModelStreamError.unknownToolCall(replacement.id) : .toolCallMismatch(replacement.id)) {
                try atCompletion.append(.toolCallCompleted(replacement))
            }
            var atTerminal = try prefix(original)
            try atTerminal.append(.toolCallCompleted(original))
            #expect(throws: ModelStreamError.responseMismatch) {
                try atTerminal.append(.responseCompleted(.init(info: info, toolCalls: [replacement], stopReason: .toolCalls)))
            }
        }
        var changedDelta = ModelEventAccumulator()
        try changedDelta.append(.responseStarted(info))
        try changedDelta.append(.toolCallStarted(original.id, name: original.name))
        #expect(throws: ModelStreamError.unknownToolCall(.init(rawValue: nfc))) {
            try changedDelta.append(.toolCallArgumentsDelta(.init(rawValue: nfc), "{}"))
        }
    }

    @Test func identicalArgumentsPassAndDifferentASCIIArgumentsReject() throws {
        let call = ToolCall(id: .init(rawValue: "call"), name: "read", argumentsJSON: "{}", completeness: .complete)
        var accepted = try prefix(call)
        try accepted.append(.toolCallCompleted(call))
        try accepted.append(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
        #expect(try accepted.finish().toolCalls == [call])
        var rejected = try prefix(call)
        #expect(throws: ModelStreamError.toolCallMismatch(call.id)) {
            try rejected.append(.toolCallCompleted(.init(id: call.id, name: call.name, argumentsJSON: "{\"changed\":true}", completeness: .complete)))
        }
    }

    private func prefix(_ call: ToolCall) throws -> ModelEventAccumulator {
        var stream = ModelEventAccumulator()
        try stream.append(.responseStarted(info))
        try stream.append(.toolCallStarted(call.id, name: call.name))
        try stream.append(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
        return stream
    }
}
