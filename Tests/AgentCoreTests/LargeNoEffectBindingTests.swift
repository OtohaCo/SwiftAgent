import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing

struct LargeNoEffectBindingTests {
    @Test(arguments: [false, true])
    func realProofBindsTheOriginalArgumentsAndUnchangedKey(_ stable: Bool) async throws {
        let directory = auditTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "large-binding", supportsConfirmedNoEffect: true)
        let counts = NoEffectCounts(); let gate = NoEffectReturnGate()
        defer { Task { await gate.release() } }
        let raw = " {\"content\":\"" + String(repeating: "x", count: 250_000) + "\"} "
        let arguments = try JSONValue.decodeToolArguments(raw)
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [.init(id: .init(rawValue: "A"), name: "no_effect_file", argumentsJSON: raw, completeness: .complete)]) : textResponse(request, "done")
        }
        let session = try Agent(model: fixtureModel, provider: provider,
            tools: [try NoEffectFileTool(file: directory.appendingPathComponent("effect"), counts: counts, largeArguments: true, beforeReturn: { await gate.enterAndWait() })]).makeSession(journal: journal)
        let run = try await session.run("write", operationID: stable ? " stable-op " : nil)
        try await gate.waitUntilEntered()
        let pending = try #require(try await journal.pendingMutations().first)
        #expect(pending.intent.call.argumentsJSON == raw)
        #expect(await provider.log.requests.count == 1)
        let outcome = try #require(await counts.saved)
        let proof = outcome.proof; let key = outcome.receipt.operationID
        #expect(pending.intent.idempotencyKey == key)
        #expect(proof.version == 2 && proof.canonicalArguments == nil && proof.receipt == nil)
        #expect(proof.receiptSummary?.operation.key.utf8Bytes == key.utf8.count)
        #expect(proof.originalArgumentsUTF8Bytes == raw.utf8.count)
        #expect(proof.argumentBinding?.utf8Bytes == 250_014)
        if stable { #expect(key == "stable-op/no_effect_file/{\"content\":\"" + String(repeating: "x", count: 250_000) + "\"}") }
        else { #expect(key == "\(run.id.uuidString)/A") }
        let bytes = try JSONEncoder().encode(proof)
        #expect(bytes.count < 4096)
        func validate(_ candidate: ToolNoEffectProof, operation: String? = nil, input: JSONValue? = nil,
                      session: UUID? = nil, runID: UUID? = nil, call: ToolCallID? = nil) throws {
            try candidate.validate(sessionID: session ?? sessionID, runID: runID ?? run.id, callID: call ?? .init(rawValue: "A"),
                name: "no_effect_file", operationID: operation ?? key, arguments: input ?? arguments,
                resources: [.global], expectation: try .init(targets: [.init(namespace: "fixture", id: "file")]),
                originalArgumentsUTF8Bytes: raw.utf8.count)
        }
        let sessionID = session.id
        try validate(proof)
        var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for field in ["argumentBinding", "operationKey", "rawBytes"] {
            for member in ["sha256", "utf8Bytes", "encoding"] {
                var altered = json
                if field == "rawBytes" { altered["originalArgumentsUTF8Bytes"] = raw.utf8.count + 1 }
                else if field == "argumentBinding" {
                    var digest = altered[field] as! [String: Any]
                    digest[member] = member == "utf8Bytes" ? 1 : "incorrect"
                    altered[field] = digest
                } else {
                    var summary = altered["receiptSummary"] as! [String: Any]
                    var operation = summary["operation"] as! [String: Any]
                    var digest = operation["key"] as! [String: Any]
                    digest[member] = member == "utf8Bytes" ? 1 : "incorrect"
                    operation["key"] = digest; summary["operation"] = operation; altered["receiptSummary"] = summary
                }
                let forged = try JSONDecoder().decode(ToolNoEffectProof.self, from: JSONSerialization.data(withJSONObject: altered))
                #expect(throws: ToolNoEffectError.invalidBinding) { try validate(forged) }
                await #expect(throws: ToolNoEffectError.invalidBinding) {
                    try await journal.commitExecutorNoEffect(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A"),
                        proof: forged, message: .init(callID: .init(rawValue: "A"), content: [.text("refused")], isError: true),
                        history: [], auditDrafts: [])
                }
                #expect(try await journal.pendingMutations().first?.state == .intent)
            }
        }
        // A well-formed binding for different original material must also fail commit.
        var otherMaterial = json
        let otherArguments = JSONValue.object(["content": .string(String(repeating: "y", count: 250_000))])
        otherMaterial["argumentBinding"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ToolNoEffectDigest.arguments(otherArguments)))
        let otherProof = try JSONDecoder().decode(ToolNoEffectProof.self, from: JSONSerialization.data(withJSONObject: otherMaterial))
        await #expect(throws: ToolNoEffectError.invalidBinding) {
            try await journal.commitExecutorNoEffect(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A"),
                proof: otherProof, message: .init(callID: .init(rawValue: "A"), content: [.text("refused")], isError: true), history: [], auditDrafts: [])
        }
        #expect(throws: ToolNoEffectError.invalidBinding) { try validate(proof, operation: key + "x") }
        #expect(throws: ToolNoEffectError.invalidBinding) { try validate(proof, input: .object(["content": .string(String(repeating: "x", count: 249_999) + "y")])) }
        #expect(throws: ToolNoEffectError.invalidBinding) { try validate(proof, session: UUID()) }
        #expect(throws: ToolNoEffectError.invalidBinding) { try validate(proof, runID: UUID()) }
        #expect(throws: ToolNoEffectError.invalidBinding) { try validate(proof, call: .init(rawValue: "new-call")) }
        json["version"] = 1
        let fakeV1 = try JSONDecoder().decode(ToolNoEffectProof.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: ToolNoEffectError.invalidBinding) { try validate(fakeV1) }
        #expect(try await journal.executorNoEffectConfirmation(sessionID: sessionID, runID: run.id, callID: .init(rawValue: "A")) == nil)
        await gate.release()
        let result = try await run.wait(); try await run.waitForDrain()
        #expect(result.receipts.isEmpty)
        #expect(await counts.effects == 0)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.executorNoEffectConfirmation(sessionID: sessionID, runID: run.id, callID: .init(rawValue: "A"))?.executorProof == proof)
        try await reopened.close()
    }
}
