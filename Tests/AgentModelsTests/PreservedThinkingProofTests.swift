import AgentModels
import Foundation
import Testing

struct PreservedThinkingProofTests {
    @Test func malformedPersistedProofsAndPublicConstructionHaveSameValidation() throws {
        let hash = String(repeating: "a", count: 64), sourceHash = String(repeating: "b", count: 16)
        let witness = try ModelPreservedThinkingRequestWitness(prefixDigest: hash, rootToolsDigest: hash, qualificationScope: hash)
        let boundary = try ModelProviderRequestBoundary(id: UUID(),
            source: .init(sessionID: UUID(), canonicalMessageCount: 1, lastMessageID: UUID(), canonicalDigest: sourceHash,
                requestDigest: hash, projectionID: "identity", projectionVersion: "1", previousCheckpointID: nil),
            invocationID: UUID(), origin: .init(providerID: "anthropic", serviceInstanceID: "qualified",
                endpointScope: "https://fixture.invalid", apiDialect: "anthropic", configurationRevision: "1"),
            rootConfigurationDigest: sourceHash, tools: [], conversationControls: nil, witness: witness)
        let lineage = try ModelPreservedThinkingLineage(boundary: boundary, parentCheckpointID: nil,
            tailMessageCount: 1, tailDigest: sourceHash, replacements: [])
        #expect(try JSONDecoder().decode(ModelPreservedThinkingLineage.self, from: JSONEncoder().encode(lineage)) == lineage)
        #expect(throws: ModelProviderError.self) {
            try ModelPreservedThinkingLineage(boundary: boundary, parentCheckpointID: UUID(), tailMessageCount: 1, tailDigest: sourceHash, replacements: [])
        }
        #expect(throws: ModelProviderError.self) {
            try ModelPreservedThinkingRequestWitness(prefixDigest: "not-a-witness", rootToolsDigest: hash, qualificationScope: hash)
        }
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(lineage)) as? [String: Any])
        fields["tailMessageCount"] = -1
        let invalid = try JSONSerialization.data(withJSONObject: fields)
        #expect(throws: ModelProviderError.self) { try JSONDecoder().decode(ModelPreservedThinkingLineage.self, from: invalid) }
        fields["tailMessageCount"] = 1; fields["parentCheckpointID"] = UUID().uuidString
        let wrongParent = try JSONSerialization.data(withJSONObject: fields)
        #expect(throws: ModelProviderError.self) { try JSONDecoder().decode(ModelPreservedThinkingLineage.self, from: wrongParent) }
        let oldContinuation: (ModelID, String, Data, ModelProviderContinuationOrigin?, ModelNativeContextTransition?) -> ModelProviderContinuation = ModelProviderContinuation.init
        let old = oldContinuation(.init(provider: "fixture", name: "model"), "fixture", Data(), nil, nil)
        #expect(try JSONDecoder().decode(ModelProviderContinuation.self, from: JSONEncoder().encode(old)).requestBoundary == nil)
    }
}
