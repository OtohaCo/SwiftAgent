import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentJournalFileStore

struct CompactNoEffectDiskTests {
    @Test(arguments: ["arguments", "key", "digest", "bytes", "rawBytes", "session", "run", "call"])
    func restoredProofIsIndependentlyBoundToTheDiskIntent(_ tamper: String) throws {
        let (disk, _) = try fixture(version: 2)
        let encoded = try JSONEncoder().encode(disk)
        #expect(try JSONDecoder().decode(DiskMutationV1.self, from: encoded).value().state == .aborted)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var intent = json["intent"] as! [String: Any]
        var proof = json["executorNoEffectProof"] as! [String: Any]
        switch tamper {
        case "arguments":
            var call = intent["call"] as! [String: Any]
            call["arguments"] = "{\"content\":\"" + String(repeating: "y", count: 143_000) + "\"}"
            intent["call"] = call; json["intent"] = intent
        case "key": intent["identity"] = "different-key"; json["intent"] = intent
        case "digest", "bytes":
            var digest = proof["argumentBinding"] as! [String: Any]
            digest[tamper == "digest" ? "sha256" : "utf8Bytes"] = tamper == "digest" ? "incorrect" : 143_015
            proof["argumentBinding"] = digest; json["executorNoEffectProof"] = proof
        case "rawBytes": proof["originalArgumentsUTF8Bytes"] = 1; json["executorNoEffectProof"] = proof
        case "session": json["sessionID"] = UUID().uuidString
        case "run": json["runID"] = UUID().uuidString
        case "call":
            var call = intent["call"] as! [String: Any]
            call["id"] = "new-call"
            intent["call"] = call; json["intent"] = intent
        default: Issue.record("unknown fixture")
        }
        let forged = try JSONDecoder().decode(DiskMutationV1.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: (any Error).self) { try forged.value() }
    }

    @Test func validV1KeepsItsHistoricalReceiptAndInlineRepresentation() throws {
        let (disk, proof) = try fixture(version: 1)
        // Existing v1 did not impose the new generation limit on receipt revision.
        #expect(proof.receipt?.revision?.utf8.count == 8192)
        #expect(proof.argumentBinding == nil && proof.receiptSummary == nil)
        let restored = try JSONDecoder().decode(DiskMutationV1.self, from: JSONEncoder().encode(disk)).value()
        #expect(restored.abortConfirmation?.executorProof == proof)
    }

    private func fixture(version: Int) throws -> (DiskMutationV1, ToolNoEffectProof) {
        let raw = version == 1 ? "{}" : "{\"content\":\"" + String(repeating: "x", count: 143_000) + "\"}"
        let session = UUID(), run = UUID(), call = ToolCallID(rawValue: "A")
        let key = "disk-op/file/" + raw
        let context = ToolContext(sessionID: session, runID: run, callID: call, idempotencyKey: key, argumentsJSON: raw)
        let definition = ModelToolDefinition(name: "file", description: "Temporary fixture", inputSchema: ToolSchema.object(properties: ["content": .string]).json, outputSchema: ToolSchema.string.json)
        let expectation = try ToolReceiptExpectation(targets: [.init(namespace: "fixture", id: "file")])
        let action = ToolAuthorizationBinding(implementationVersion: "1", backend: .init(instanceID: "local", version: "1", accountID: "fixture", credentialGeneration: "1"))
        let proof = try ToolNoEffectProof.make(version: version, invocationID: UUID(), context: context,
            definition: definition, arguments: JSONValue.decodeToolArguments(raw), resources: [.global], action: action,
            expectation: expectation, receipt: .init(operationID: key, status: .failed, confirmedTargets: [], revision: version == 1 ? String(repeating: "x", count: 8192) : nil, failure: .rejected), basis: "no effect before write")
        let intent = try PendingMutationIntent(call: .init(id: call, name: "file", argumentsJSON: raw, completeness: .complete), resources: [.global], idempotencyKey: key, receiptExpectation: expectation)
        let stored = JournalStoredMutation(sessionID: session, runID: run, intent: intent, sequence: 1, state: .aborted, abortConfirmation: .init(executorProof: proof))
        return (try DiskMutationV1(stored), proof)
    }
}
