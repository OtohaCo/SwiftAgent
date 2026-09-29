import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentProviders
import AgentTools
import ExecutionReportingSupport
import Foundation

@main struct ReplanningEvalTrial {
    static func main() async {
        guard CommandLine.arguments.count == 3 else {
            FileHandle.standardError.write(Data("usage: ReplanningEvalTrial INPUT.json RESULT.json\n".utf8))
            exit(64)
        }
        do {
            let input = try JSONDecoder().decode(TrialInput.self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            let result = try await evaluate(input)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        } catch {
            // Neither the input JSON nor credentials are included in errors.
            FileHandle.standardError.write(Data("Trial fixture or configuration failed: \(type(of: error))\n".utf8))
            exit(1)
        }
    }

    private static func evaluate(_ input: TrialInput) async throws -> TrialFacts {
        guard ["dry-run", "live"].contains(input.mode), ["disabled", "enabled"].contains(input.arm),
              !input.trialID.isEmpty, !input.operationID.isEmpty,
              input.maxHTTPRequests > 0, input.maxOutputTokens > 0, input.maxInputBytes > 0,
              input.maxModelTurns > 0, input.maxToolCalls > 0, input.runTimeoutSeconds > 0,
              FileManager.default.fileExists(atPath: input.directory) else {
            throw EvalTrialError.invalidConfiguration
        }
        let task = input.task
        let trialDirectory = URL(fileURLWithPath: input.directory)
        let effectFile = trialDirectory.appendingPathComponent("effects.txt")
        try Data().write(to: effectFile, options: .withoutOverwriting)
        let probe = TrialProbe(maxHTTPRequests: input.maxHTTPRequests)
        let gate: TrialGate? = input.mode == "dry-run" &&
            ["cancel_after_request", "revoke_after_request"].contains(task.scenario) ? TrialGate() : nil
        let underlying: any ModelProvider
        let model: ModelID
        if input.mode == "live" {
            guard input.authorizedLive,
                  let endpointText = input.endpoint,
                  let endpoint = URL(string: endpointText),
                  endpoint.scheme == "https", endpoint.user == nil, endpoint.password == nil,
                  endpoint.query == nil, endpoint.fragment == nil,
                  let keyName = input.keyEnvironment,
                  keyName.range(of: "^[A-Z][A-Z0-9_]*$", options: .regularExpression) != nil,
                  let key = ProcessInfo.processInfo.environment[keyName], !key.isEmpty else {
                throw EvalTrialError.invalidConfiguration
            }
            let effort = input.reasoning == "none" ? nil : OpenAIReasoningEffort(rawValue: input.reasoning)
            guard ["none", "minimal", "low", "medium", "high", "xhigh", "max"].contains(input.reasoning)
            else { throw EvalTrialError.invalidConfiguration }
            underlying = try OpenAIResponsesProvider(apiKey: key, endpoint: endpoint,
                maximumOutputTokens: input.maxOutputTokens, reasoningEffort: effort,
                transport: TrialHTTPTransport(probe: probe, wrapped: URLSessionProviderHTTPTransport()))
            model = .init(provider: "openai", name: input.model)
        } else {
            underlying = DryTrialProvider(task: task)
            model = .init(provider: "eval-dry", name: "scripted")
        }
        let provider = ObservedProvider(wrapped: underlying, probe: probe, gate: gate)
        let journal = try AgentIncrementalJournal.create(at: trialDirectory.appendingPathComponent("journal"),
            operationDomain: "evaluation.\(input.trialID)", supportsAdmissionRejections: true)
        let policy: AgentPreAdmissionReplanning = input.arm == "enabled"
            ? .evidenceRejection(toolNames: [EvalCommit.name]) : .disabled
        let search = EvalSearch(task: task, probe: probe)
        let commit = EvalCommit(task: task, probe: probe, file: effectFile)
        let agent = try Agent(model: model, provider: provider, tools: [search, commit],
            configuration: .init(instructions: "Use search_candidates before committing. Commit only an evidenced resource. "
                + "Respect explicit requests not to commit. Report real tool outcomes, not intentions.",
                maxModelTurns: input.maxModelTurns, maxToolCalls: input.maxToolCalls,
                runTimeout: .seconds(input.runTimeoutSeconds),
                contextPolicy: .init(maxInputUTF8Bytes: input.maxInputBytes,
                                     maxModelContextUTF8Bytes: input.maxInputBytes),
                preAdmissionReplanning: policy))
        let session = try agent.makeSession(journal: journal)
        let budget = try AgentBudget(maxModelTurns: input.maxModelTurns, maxToolCalls: input.maxToolCalls,
            deadline: .now.advanced(by: .seconds(input.runTimeoutSeconds)))
        let scope: AgentCapabilityBinding?
        if task.scenario == "revoke_after_request" {
            scope = try await session.bindCapabilities(identity: "eval", version: "1",
                backendInstanceID: "temporary-file", backendVersion: "1",
                allowedResources: [.global] + ["A", "B", "X"].map {
                    .named(.init(namespace: "eval.resource", id: $0))
                }, tools: [.init(id: "search", version: "1", tool: search),
                           .init(id: "commit", version: "1", tool: commit)])
        } else { scope = nil }
        let firstRun: AgentRun
        if let scope {
            firstRun = try await session.run(task.prompt, capabilities: scope,
                budget: budget, operationID: input.operationID)
        } else {
            firstRun = try await session.run(task.prompt, budget: budget,
                operationID: input.operationID)
        }
        let controller: Task<Void, Never>? = gate.map { gate in
            Task {
                await probe.waitForRequests(1)
                if task.scenario == "revoke_after_request" { await scope?.revoke() }
                else { await firstRun.cancel() }
                await gate.open()
            }
        }
        var runIDs = [firstRun.id.uuidString]
        let first = await observe(firstRun, probe: probe)
        await controller?.value
        var final = first
        if task.scenario == "unknown_after_write", input.mode == "dry-run" {
            // Same Session, operation and Journal: this attempts a real admission
            // after an uncertain effect. It must never enter the executor again.
            let retry = try await session.run("Retry the same operation",
                budget: budget, operationID: input.operationID)
            runIDs.append(retry.id.uuidString)
            final = await observe(retry, probe: probe)
        }
        let effectIDs = try String(contentsOf: effectFile, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let identity = #"\#(input.operationID)/commit_resource/{"id":"A"}"#
        let status = try await journal.mutationStatus(identity: identity)
        var pending: [String]?
        var pendingError: String?
        do { pending = try await journal.pendingMutations(sessionID: session.id).map(\.state.rawValue) }
        catch { pendingError = String(describing: ExecutionReportReducer.classify(error)) }
        let seen = await probe.facts(logicalEnd: final.logicalEnd,
                                     drain: final.drain)
        try await journal.close()
        let reports = runIDs.count == 1 ? [first.report] : [first.report, final.report]
        return .init(trialID: input.trialID, mode: input.mode, arm: input.arm, taskID: task.id,
            sessionID: session.id.uuidString, runIDs: runIDs, operationID: input.operationID,
            outcome: final.outcome, failure: final.failure,
            providerRequests: seen.requests, httpRequests: seen.http,
            searches: seen.searches, toolAttempts: seen.attempts,
            executorEntered: seen.entered, effectIDs: effectIDs,
            trustedReceipts: runIDs.count == 1 ? first.report.receipts.count
                : first.report.receipts.count + final.report.receipts.count,
            settledA: status?.state == .settled,
            replayOutputA: status?.replayOutput == .object(["committed": .string("A")]),
            pendingStates: pending, pendingQueryError: pendingError,
            rejectionCallIDs: seen.rejected, feedbackInLaterRequest: seen.feedback,
            usage: seen.usage, milestonesNS: seen.time,
            reportComplete: reports.allSatisfy(\.coverage.isComplete),
            reportDiagnostics: reports.flatMap { $0.diagnostics.map(String.init(describing:)) },
            hostRetries: 0)
    }

    private struct Observation {
        let outcome: String
        let failure: String?
        let logicalEnd: UInt64
        let drain: UInt64
        let report: RunExecutionReport
    }

    private static func observe(_ run: AgentRun, probe: TrialProbe) async -> Observation {
        let stream = Task { () -> ExecutionReportReducer in
            var reducer = ExecutionReportReducer(sessionID: run.sessionID, runID: run.id)
            for await event in run.events {
                reducer.consume(event)
                await probe.observe(event)
            }
            reducer.markStreamEnded()
            return reducer
        }
        let result: Result<AgentLoopResult, Error>
        do { result = .success(try await run.wait()) }
        catch { result = .failure(error) }
        let logical = await probe.monotonicNow()
        let drainFailure: String?
        do { try await run.waitForDrain(); drainFailure = nil }
        catch { drainFailure = String(describing: ExecutionReportReducer.classify(error)) }
        let drained = await probe.monotonicNow()
        var reducer = await stream.value
        switch result {
        case .success(let value): reducer.recordWait(.success(value))
        case .failure(let error): reducer.recordWait(.failure(ExecutionReportReducer.classify(error)))
        }
        if drainFailure == nil { reducer.markDrainCompleted() }
        let outcome: String
        let failure: String?
        switch result {
        case .success(let value): outcome = String(describing: value.outcome); failure = drainFailure
        case .failure(let error): outcome = error is CancellationError ? "cancelled" : "failed"
            failure = String(describing: ExecutionReportReducer.classify(error))
        }
        return .init(outcome: outcome, failure: failure,
                     logicalEnd: logical, drain: drained, report: reducer.report)
    }
}
