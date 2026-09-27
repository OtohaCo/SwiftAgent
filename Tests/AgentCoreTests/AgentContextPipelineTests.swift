import AgentCore
import AgentModels
import AgentJournalFileStore
import Foundation
import Testing

struct AgentContextPipelineTests {
    private let session = UUID()
    private let model = ModelID(provider: "fixture", name: "small")

    private func input(_ messages: [ModelMessage], ids: [Int: UUID] = [:]) -> AgentContextProjectionInput {
        .init(canonicalMessages: messages, model: model, sessionID: session, runID: UUID(),
              conversationRevision: 3, contextEpoch: 3, modelTurn: 1, formalMessageIDs: ids)
    }

    @Test func orderDedupScopeAndConflict() async throws {
        let skill = AgentContextMaterial(id: "skill", version: "1", kind: .skill, sessionID: session,
                                         text: "approved skill", priority: 5)
        let file = AgentContextMaterial(id: "file", version: "1", kind: .file, sessionID: session,
                                        text: "file excerpt", priority: 10)
        let canonical: [ModelMessage] = [.system("current"), .user([.text("latest")])]
        let left = try await AgentCompositeContextProjector(materials: [file, skill, skill]).project(input(canonical))
        let right = try await AgentCompositeContextProjector(materials: [skill, file]).project(input(canonical))
        #expect(left.messages == right.messages)
        #expect(left.messages.first == .system("current"))
        #expect(left.messages.last == canonical.last)
        #expect(left.report?.acceptedCount == 2)

        let foreign = AgentContextMaterial(id: "foreign", version: "1", kind: .skill,
                                           sessionID: UUID(), text: "private")
        await #expect(throws: AgentContextPipelineError.scopeMismatch) {
            try await AgentCompositeContextProjector(materials: [foreign]).project(input(canonical))
        }
        let conflict = AgentContextMaterial(id: "skill", version: "1", kind: .skill,
                                            sessionID: session, text: "different")
        await #expect(throws: AgentContextPipelineError.conflictingMaterial) {
            try await AgentCompositeContextProjector(materials: [skill, conflict]).project(input(canonical))
        }
    }

    @Test func summaryChecksIdsAndRangeButSurvivesUnrelatedAppend() async throws {
        let old: [ModelMessage] = [.user([.text("old")]), .assistant(content: [.text("answer")], toolCalls: [])]
        let ids = [UUID(), UUID()]
        let span = AgentContextHistorySpan(sessionID: session, start: 0, messageIDs: ids,
                                            sourceDigest: try AgentContextProjectionSource.digest(messages: old))
        let summary = AgentContextSummary(span: span, generatorVersion: "fixture-1", text: "earlier question answered")
        let projector = AgentCompositeContextProjector(summaries: [summary])
        let canonical = old + [.user([.text("latest")])]
        let result = try await projector.project(input(canonical, ids: [0: ids[0], 1: ids[1]]))
        #expect(result.messages.count == 2)
        #expect(result.messages.last == canonical.last)
        _ = try await projector.project(input(canonical + [.assistant(content: [.text("next")], toolCalls: []), .user([.text("new")])], ids: [0: ids[0], 1: ids[1]]))
        await #expect(throws: AgentContextPipelineError.staleSummary) {
            try await projector.project(input([.user([.text("changed")]), old[1], canonical[2]], ids: [0: ids[0], 1: ids[1]]))
        }
        await #expect(throws: AgentContextPipelineError.staleSummary) {
            try await projector.project(input(canonical, ids: [0: UUID(), 1: ids[1]]))
        }
        await #expect(throws: AgentContextPipelineError.unsafeSummary) {
            try await AgentCompositeContextProjector(summaries: [summary],
                protectedMessageIDs: [ids[0]]).project(input(canonical, ids: [0: ids[0], 1: ids[1]]))
        }
    }

    @Test func summaryNeverHidesDeniedOrUnresolvedToolFacts() async throws {
        let call = ToolCall(id: .init(rawValue: "denied"), name: "mutate",
                            argumentsJSON: "{}", completeness: .complete)
        let prefix: [ModelMessage] = [.user([.text("old")]),
            .assistant(content: [], toolCalls: [call]),
            .tool(.init(callID: call.id, content: [.text("permission denied")], isError: true))]
        let ids = [UUID(), UUID(), UUID()]
        let summary = AgentContextSummary(span: .init(sessionID: session, start: 0, messageIDs: ids,
            sourceDigest: try AgentContextProjectionSource.digest(messages: prefix)),
            generatorVersion: "v1", text: "safe now")
        let projector = AgentCompositeContextProjector(summaries: [summary])
        await #expect(throws: AgentContextPipelineError.unsafeSummary) {
            try await projector.project(input(prefix + [.user([.text("next")])],
                                              ids: [0: ids[0], 1: ids[1], 2: ids[2]]))
        }
        let unresolved = Array(prefix.prefix(2)) + [.user([.text("next")])]
        await #expect(throws: AgentContextPipelineError.unsafeSummary) {
            try await projector.project(input(unresolved, ids: [0: ids[0], 1: ids[1]]))
        }
    }

    @Test func mandatoryMaterialLimitAndOptionalOmission() async throws {
        let material = AgentContextMaterial(id: "large", version: "1", kind: .retrieval,
                                            sessionID: session, text: String(repeating: "x", count: 200), required: true)
        await #expect(throws: AgentContextPipelineError.requiredMaterialTooLarge) {
            try await AgentCompositeContextProjector(materials: [material], limits: .init(maxMaterialBytes: 100))
                .project(input([.user([.text("latest")])]))
        }
        let optional = AgentContextMaterial(id: "large", version: "1", kind: .retrieval,
                                            sessionID: session, text: String(repeating: "x", count: 200), required: false)
        let result = try await AgentCompositeContextProjector(materials: [optional], limits: .init(maxMaterialBytes: 100))
            .project(input([.user([.text("latest")])]))
        #expect(result.report?.omittedCount == 1)
    }

    @Test func realSessionPreflightAndReopenKeepFormalHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("context-pipeline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "context-fixture")
        let provider = ScriptedProvider { request, _ in textResponse(request, "answer") }
        let agent = try Agent(model: model, provider: provider)
        let a = try agent.makeSession(id: session, journal: journal)
        let b = try agent.makeSession(id: UUID(), journal: journal)
        let first = try await a.run("old question")
        _ = try await first.wait()
        try await first.waitForDrain()
        let span = try await a.contextHistorySpan(start: 0, count: 2)
        let reports = AgentContextReportBuffer(capacity: 1)
        let projectA = AgentCompositeContextProjector(
            materials: [.init(id: "project-A", version: "1", kind: .skill,
                              sessionID: session, text: "project A rule")],
            summaries: [.init(span: span, generatorVersion: "fixture-v1", text: "old question answered")])
        let bindingA = try AgentModelBinding(profileID: "a", profileRevision: "1", model: model,
                                               provider: provider, deployment: try .init(serviceInstanceID: "a", endpointScope: "fixture", apiDialect: "fixture"),
                                               projector: projectA, contextReports: reports)
        let second = try await a.run("latest", using: bindingA)
        _ = try await second.wait()
        try await second.waitForDrain()
        let requestA = try #require(await provider.log.requests.last)
        #expect(requestA.messages.contains(.user([.text("latest")])))
        #expect(!requestA.messages.contains(.user([.text("old question")])))
        #expect(await reports.reports().count == 1)

        let projectB = AgentCompositeContextProjector(materials: [
            .init(id: "project-B", version: "1", kind: .skill,
                  sessionID: b.id, text: "project B rule")
        ])
        let bindingB = try AgentModelBinding(profileID: "b", profileRevision: "1", model: model,
                                               provider: provider, deployment: try .init(serviceInstanceID: "b", endpointScope: "fixture", apiDialect: "fixture"), projector: projectB)
        let third = try await b.run("other", using: bindingB)
        _ = try await third.wait()
        try await third.waitForDrain()
        let requestB = try #require(await provider.log.requests.last)
        #expect(!String(describing: requestB.messages).contains("project A rule"))

        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let restored = try agent.makeSession(id: session, journal: reopened)
        let snapshot = try await restored.conversationSnapshot()
        #expect(snapshot.messages.contains(.user([.text("old question")])))
        #expect(snapshot.messages.contains(.user([.text("latest")])))
        try await reopened.close()
    }

    @Test func forwardingProjectorPreservesVerifiedSummaryAndReadOnlyExcerpt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("context-wrapper-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "wrapper")
        let provider = ScriptedProvider { request, _ in
            if request.messages.last == .user([.text("lookup")]) {
                return toolResponse(request, [addition(request.sessionID!.uuidString)])
            }
            return textResponse(request, "done")
        }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [try AddTool(log: EffectLog())])
        for wrapped in [false, true] {
            let session = try agent.makeSession(journal: journal)
            let first = try await session.run("old")
            _ = try await first.wait(); try await first.waitForDrain()
            let second = try await session.run("lookup")
            _ = try await second.wait(); try await second.waitForDrain()
            let span = try await session.contextHistorySpan(start: 0, count: 2)
            let excerpt = try await session.contextToolExcerpt(
                callID: .init(rawValue: session.id.uuidString), text: "five")
            let composite = AgentCompositeContextProjector(
                summaries: [.init(span: span, generatorVersion: "v1", text: "old answered")],
                excerpts: [excerpt])
            let projector: any AgentContextProjector = wrapped
                ? ForwardingContextProjector(inner: composite) : composite
            let binding = try AgentModelBinding(profileID: "wrapper", profileRevision: "1",
                model: fixtureModel, provider: provider,
                deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
                projector: projector)
            let run = try await session.run("next", using: binding)
            _ = try await run.wait(); try await run.waitForDrain()
            let sent = try #require(await provider.log.requests.last)
            #expect(String(describing: sent.messages).contains("Host-derived lossy summary"))
            #expect(String(describing: sent.messages).contains("read-only result excerpt"))
        }
        try await journal.close()
    }

    @Test func reopenedReadOnlyHistoryWithoutEffectProofFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("context-old-read-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "old-read")
        let id = UUID()
        let callID = ToolCallID(rawValue: "old-read")
        let provider = ScriptedProvider { request, _ in
            request.messages.last == .user([.text("lookup")])
                ? toolResponse(request, [addition(callID.rawValue)]) : textResponse(request, "done")
        }
        let originalAgent = try Agent(model: fixtureModel, provider: provider,
                                      tools: [try AddTool(log: EffectLog())])
        let original = try originalAgent.makeSession(id: id, journal: journal)
        let run = try await original.run("lookup")
        _ = try await run.wait(); try await run.waitForDrain()
        _ = try await original.contextToolExcerpt(callID: callID, text: "five")
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        let withoutTool = try Agent(model: fixtureModel, provider: provider).makeSession(id: id, journal: reopened)
        await #expect(throws: AgentContextPipelineError.unsafeToolExcerpt) {
            try await withoutTool.contextToolExcerpt(callID: callID, text: "five")
        }
        try await reopened.close()
    }

    @Test func summaryRequiresWholeClosedTextGroupAndProtectedExcerptCannotBeShortened() async throws {
        let old: [ModelMessage] = [.user([.text("old")]), .assistant(content: [.text("answer")], toolCalls: [])]
        let id = UUID()
        let half = AgentContextSummary(span: .init(sessionID: session, start: 1, messageIDs: [id],
            sourceDigest: try AgentContextProjectionSource.digest(messages: [old[1]])),
            generatorVersion: "v1", text: "only an answer")
        await #expect(throws: AgentContextPipelineError.unsafeSummary) {
            try await AgentCompositeContextProjector(summaries: [half]).project(
                input(old + [.user([.text("latest")])], ids: [1: id]))
        }
        let call = ToolCall(id: .init(rawValue: "protected"), name: "lookup", argumentsJSON: "{}", completeness: .complete)
        let result = ModelMessage.tool(.init(callID: call.id, content: [.text("complete")], isError: false))
        let excerpt = AgentContextToolExcerpt(callID: call.id, messageID: id,
            sourceDigest: try AgentContextProjectionSource.digest(messages: [result]), text: "partial")
        let messages: [ModelMessage] = [.user([.text("read")]), .assistant(content: [], toolCalls: [call]),
                                        result, .user([.text("latest")])]
        await #expect(throws: AgentContextPipelineError.unsafeToolExcerpt) {
            try await AgentCompositeContextProjector(excerpts: [excerpt], protectedMessageIDs: [id]).project(
                .init(canonicalMessages: messages, model: model, sessionID: session, runID: UUID(),
                      conversationRevision: 1, contextEpoch: 1, modelTurn: 1,
                      formalMessageIDs: [2: id], verifiedReadOnlyResults: [
                          call.id: .init(toolName: "lookup", sourceDigest: excerpt.sourceDigest)]))
        }
    }

    @Test func optionalMaterialCannotDisplaceLaterRequiredMaterial() async throws {
        let optional = AgentContextMaterial(id: "a", version: "v1", kind: .file,
            sessionID: session, text: String(repeating: "o", count: 80), required: false, priority: 0)
        let required = AgentContextMaterial(id: "z", version: "v1", kind: .skill,
            sessionID: session, text: String(repeating: "r", count: 30), required: true, priority: 10)
        let result = try await AgentCompositeContextProjector(
            materials: [optional, required], limits: .init(maxMaterialBytes: 100))
            .project(input([.user([.text("latest")])]))
        #expect(result.report?.acceptedCount == 1)
        #expect(result.report?.omittedCount == 1)
        #expect(String(describing: result.messages).contains(String(repeating: "r", count: 30)))
    }

    @Test func sourceSnapshotChangesWithSummaryExcerptAndPolicy() async throws {
        let old: [ModelMessage] = [.user([.text("old")]), .assistant(content: [.text("answer")], toolCalls: [])]
        let ids = [UUID(), UUID()]
        let span = AgentContextHistorySpan(sessionID: session, start: 0, messageIDs: ids,
            sourceDigest: try AgentContextProjectionSource.digest(messages: old))
        let source = input(old + [.user([.text("latest")])], ids: [0: ids[0], 1: ids[1]])
        let one = try #require(await AgentCompositeContextProjector(summaries: [
            .init(span: span, generatorVersion: "v1", text: "summary one")
        ]).project(source).report?.sourceSnapshot)
        for changed in [AgentCompositeContextProjector(summaries: [
                            .init(span: span, generatorVersion: "v2", text: "summary one")]),
                        AgentCompositeContextProjector(summaries: [
                            .init(span: span, generatorVersion: "v1", text: "summary two")]),
                        AgentCompositeContextProjector(summaries: [
                            .init(span: span, generatorVersion: "v1", text: "summary one")], policyVersion: "2")] {
            let snapshot = try #require(await changed.project(source).report?.sourceSnapshot)
            #expect(snapshot != one)
        }
        let call = ToolCall(id: .init(rawValue: "read"), name: "lookup", argumentsJSON: "{}", completeness: .complete)
        let result = ModelMessage.tool(.init(callID: call.id, content: [.text("full")], isError: false))
        let resultID = UUID()
        let complete: [ModelMessage] = [.user([.text("read")]), .assistant(content: [], toolCalls: [call]),
                                        result, .user([.text("latest")])]
        let digest = try AgentContextProjectionSource.digest(messages: [result])
        let excerptInput = AgentContextProjectionInput(canonicalMessages: complete, model: model,
            sessionID: session, runID: UUID(), conversationRevision: 1, contextEpoch: 1,
            modelTurn: 1, formalMessageIDs: [2: resultID], verifiedReadOnlyResults: [
                call.id: .init(toolName: "lookup", sourceDigest: digest)])
        let excerptOne = try #require(await AgentCompositeContextProjector(excerpts: [
            .init(callID: call.id, messageID: resultID, sourceDigest: digest, text: "excerpt one")
        ]).project(excerptInput).report?.sourceSnapshot)
        let excerptTwo = try #require(await AgentCompositeContextProjector(excerpts: [
            .init(callID: call.id, messageID: resultID, sourceDigest: digest, text: "excerpt two")
        ]).project(excerptInput).report?.sourceSnapshot)
        #expect(excerptOne != excerptTwo)
        let protected = try #require(await AgentCompositeContextProjector(summaries: [
            .init(span: span, generatorVersion: "v1", text: "summary one")
        ], protectedMessageIDs: [resultID])
            .project(source).report?.sourceSnapshot)
        #expect(protected != one)
    }

    @Test func mixedToolBatchExcerptsOnlyTheHistoricallyVerifiedReadOnlyResult() async throws {
        let read = ToolCall(id: .init(rawValue: "read"), name: "lookup", argumentsJSON: "{}", completeness: .complete)
        let write = ToolCall(id: .init(rawValue: "write"), name: "update", argumentsJSON: "{}", completeness: .complete)
        let readResult = ModelMessage.tool(.init(callID: read.id, content: [.text("read output")], isError: false))
        let writeResult = ModelMessage.tool(.init(callID: write.id, content: [.text("mutation output")], isError: false))
        let ids = [UUID(), UUID()]
        let canonical: [ModelMessage] = [.user([.text("work")]), .assistant(content: [], toolCalls: [read, write]),
                                          writeResult, readResult, .user([.text("next")])]
        let readDigest = try AgentContextProjectionSource.digest(messages: [readResult])
        let writeDigest = try AgentContextProjectionSource.digest(messages: [writeResult])
        let input = AgentContextProjectionInput(canonicalMessages: canonical, model: model,
            sessionID: session, runID: UUID(), conversationRevision: 1, contextEpoch: 1,
            modelTurn: 1, formalMessageIDs: [2: ids[0], 3: ids[1]], verifiedReadOnlyResults: [
                read.id: .init(toolName: read.name, sourceDigest: readDigest)])
        let readExcerpt = AgentContextToolExcerpt(callID: read.id, messageID: ids[1],
                                                   sourceDigest: readDigest, text: "read excerpt")
        let projected = try await AgentCompositeContextProjector(excerpts: [readExcerpt]).project(input)
        #expect(projected.messages[2] == writeResult)
        #expect(projected.messages[1] == canonical[1])
        await #expect(throws: AgentContextPipelineError.unsafeToolExcerpt) {
            try await AgentCompositeContextProjector(excerpts: [
                .init(callID: write.id, messageID: ids[0], sourceDigest: writeDigest, text: "hide effect")
            ]).project(input)
        }
    }

    @Test func excerptKeepsCallPairAndRejectsMutationOrError() async throws {
        let id = UUID()
        let call = ToolCall(id: .init(rawValue: "read-1"), name: "lookup", argumentsJSON: "{}", completeness: .complete)
        let result = ModelMessage.tool(.init(callID: call.id, content: [.text(String(repeating: "record", count: 500))], isError: false))
        let messages: [ModelMessage] = [.user([.text("question")]),
                                        .assistant(content: [], toolCalls: [call]), result,
                                        .user([.text("next question")])]
        let excerpt = AgentContextToolExcerpt(callID: call.id, messageID: id,
                            sourceDigest: try AgentContextProjectionSource.digest(messages: [result]),
                            text: "record excerpt")
        let projector = AgentCompositeContextProjector(excerpts: [excerpt])
        let source = AgentContextProjectionInput(canonicalMessages: messages, model: model,
            sessionID: session, runID: UUID(), conversationRevision: 1, contextEpoch: 1,
            modelTurn: 1, formalMessageIDs: [2: id], verifiedReadOnlyResults: [
                call.id: .init(toolName: "lookup", sourceDigest: excerpt.sourceDigest)])
        let projected = try await projector.project(source)
        #expect(projected.messages.count == messages.count)
        guard case .tool(let visible) = projected.messages[2] else {
            Issue.record("Expected paired tool result"); return
        }
        #expect(visible.callID == call.id)
        #expect(!visible.isError)
        #expect(visible.content != [.text(String(repeating: "record", count: 500))])
        let mutationInput = AgentContextProjectionInput(canonicalMessages: messages, model: model,
            sessionID: session, runID: UUID(), conversationRevision: 1, contextEpoch: 1,
            modelTurn: 1, formalMessageIDs: [2: id])
        await #expect(throws: AgentContextPipelineError.unsafeToolExcerpt) {
            try await projector.project(mutationInput)
        }
        let errorMessages = [messages[0], messages[1], ModelMessage.tool(.init(callID: call.id, content: [], isError: true)), messages[3]]
        await #expect(throws: AgentContextPipelineError.staleToolExcerpt) {
            try await projector.project(.init(canonicalMessages: errorMessages, model: model,
                sessionID: session, runID: UUID(), conversationRevision: 1, contextEpoch: 1,
                modelTurn: 1, formalMessageIDs: [2: id], verifiedReadOnlyResults: [
                    call.id: .init(toolName: "lookup", sourceDigest: excerpt.sourceDigest)]))
        }
    }

    @Test func multiToolCompletionOrderStillKeepsBothResults() async throws {
        let calls = ["one", "two"].map {
            ToolCall(id: .init(rawValue: $0), name: "lookup", argumentsJSON: "{}", completeness: .complete)
        }
        for order in [calls, Array(calls.reversed())] {
            let results: [ModelMessage] = order.map { call in
                .tool(.init(callID: call.id, content: [.text("long \(call.id.rawValue)")], isError: false))
            }
            let ids = [UUID(), UUID()]
            let first = try #require(results.first)
            guard case .tool(let firstResult) = first else { Issue.record("missing result"); return }
            let excerpt = AgentContextToolExcerpt(callID: firstResult.callID, messageID: ids[0],
                sourceDigest: try AgentContextProjectionSource.digest(messages: [first]), text: "excerpt")
            let canonical: [ModelMessage] = [.user([.text("read")]),
                                              .assistant(content: [], toolCalls: calls)] + results + [.user([.text("next")])]
            let input = AgentContextProjectionInput(canonicalMessages: canonical, model: model,
                sessionID: session, runID: UUID(), conversationRevision: 1, contextEpoch: 1,
                modelTurn: 1, formalMessageIDs: [2: ids[0], 3: ids[1]], verifiedReadOnlyResults: [
                    firstResult.callID: .init(toolName: "lookup", sourceDigest: excerpt.sourceDigest)])
            let output = try await AgentCompositeContextProjector(excerpts: [excerpt]).project(input)
            #expect(output.messages.count == canonical.count)
            #expect(output.messages[3] == canonical[3])
            #expect(output.messages[1] == canonical[1])
        }
    }

    @Test func reportIsBoundedAndContainsNoText() async throws {
        let buffer = AgentContextReportBuffer(capacity: 2)
        let projector = AgentCompositeContextProjector(materials: [
            .init(id: "/private/secret/file", version: "v1", kind: .file,
                  sessionID: session, text: "credential-string")
        ])
        for _ in 0..<3 {
            let report = try #require(await projector.project(input([.user([.text("prompt-secret")])])).report)
            await buffer.append(report)
        }
        let reports = await buffer.reports()
        #expect(reports.count == 2)
        let json = String(decoding: try JSONEncoder().encode(reports), as: UTF8.self)
        #expect(!json.contains("credential-string"))
        #expect(!json.contains("/private/secret/file"))
        #expect(!json.contains("prompt-secret"))
    }

    @Test func assembledRequestPassesExistingTokenBudgetBeforeAdmission() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "unexpected") }
        let session = try Agent(model: model, provider: provider).makeSession(id: self.session)
        let reports = AgentContextReportBuffer()
        let binding = try AgentModelBinding(
            profileID: "small-context", profileRevision: "1", model: model,
            provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
            projector: AgentCompositeContextProjector(materials: [
                .init(id: "necessary", version: "v1", kind: .skill, sessionID: self.session,
                      text: String(repeating: "data", count: 200))
            ]),
            tokenBudget: .init(maximumContextTokens: 20, reservedOutputTokens: 5,
                               estimator: HighEstimate()), contextReports: reports)
        await #expect(throws: AgentModelBindingError.contextBudgetExceeded(
            estimatedInputTokens: 100, availableInputTokens: 15)) {
            try await session.run("uncommitted input", using: binding)
        }
        #expect(await provider.log.requests.isEmpty)
        #expect(!(await session.history).contains(.user([.text("uncommitted input")])))
        #expect(await reports.reports().first?.failureCode == "input_tokens_exceeded")
    }
}

private struct HighEstimate: AgentContextTokenEstimator {
    func estimate(_ input: AgentContextTokenEstimationInput) async throws -> AgentContextTokenEstimate {
        #expect(input.messages.contains(where: { String(describing: $0).contains("necessary") }) == false)
        #expect(input.messages.count == 2)
        return .init(inputTokens: 100, accuracy: .estimated)
    }
}

private struct ForwardingContextProjector: AgentContextSourceReferencing {
    let inner: AgentCompositeContextProjector
    var historySpans: [AgentContextHistorySpan] { inner.historySpans }
    var toolResultCallIDs: [ToolCallID] { inner.toolResultCallIDs }

    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        try await inner.project(input)
    }
}
