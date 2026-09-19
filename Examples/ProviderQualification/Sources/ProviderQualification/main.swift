import Foundation
import LiveProviderSupport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
enum ProviderQualificationMain {
    static func main() async {
        do {
            let options = try QualificationOptions.parse(Array(CommandLine.arguments.dropFirst()))
            let process = ProcessInfo.processInfo.environment
            let environmentFile = options.environmentFile
                ?? process["SWIFT_AGENT_LIVE_ENV_FILE"].map { URL(fileURLWithPath: $0).standardizedFileURL }
                ?? defaultEnvironmentFile()
            let environment = try LiveEnvironment.load(process: process, fileURL: environmentFile)
            let preflight = try QualificationConfiguration.preflight(options: options, environment: environment)
            write(preflight.rendered)
            write(renderedEnvironmentFileStatus(environmentFile))

            guard options.scenario != .preflight else { return }
            let budgetFile = options.budgetFile
                ?? environment.value(for: "SWIFT_AGENT_LIVE_BUDGET_FILE")
                    .map { URL(fileURLWithPath: $0).standardizedFileURL }
            let budget = try LiveRequestBudget(fileURL: budgetFile)
            let configuration = try QualificationConfiguration.resolve(options: options, environment: environment)
            let evidence = RequestEvidenceLedger()
            let runner = try QualificationRunner(
                configuration: configuration,
                budget: budget,
                evidence: evidence
            )
            let results = await runner.runSelected()
            for result in results { write(result.rendered) }
            for entry in await runner.requestEvidence() { write(entry.description) }
            for entry in await evidence.responses { write(entry.description) }
            let snapshot = await budget.snapshot()
            write("budget_total_attempts=\(snapshot.totalAttempts) budget_total_remaining=\(max(0, snapshot.totalLimit - snapshot.totalAttempts))")

            if results.contains(where: { $0.status != .pass }) { exit(3) }
        } catch let error as LiveConfigurationError {
            writeError("configuration=\(safeConfigurationMessage(error))")
            exit(2)
        } catch let error as LiveBudgetError {
            writeError("budget=\(safeBudgetMessage(error))")
            exit(3)
        } catch {
            writeError("qualification=FAILED")
            exit(1)
        }
    }

    private static func defaultEnvironmentFile() -> URL? {
        let candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".env.live")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private static func write(_ value: String) {
        FileHandle.standardOutput.write(Data((value + "\n").utf8))
    }

    private static func writeError(_ value: String) {
        FileHandle.standardError.write(Data((value + "\n").utf8))
    }
}

private func safeConfigurationMessage(_ error: LiveConfigurationError) -> String {
    switch error {
    case .invalidArgument: "INVALID_ARGUMENT"
    case .unsafeEnvironmentFile: "UNSAFE_ENVIRONMENT_FILE"
    case .unreadableEnvironmentFile: "UNREADABLE_ENVIRONMENT_FILE"
    case .invalidEndpoint: "INVALID_ENDPOINT"
    case .missingCredential(let variable): "MISSING_\(variable)"
    case .missingModel(let variable): "MISSING_\(variable)"
    case .unsupportedCombination(let provider, let scenario):
        "UNSUPPORTED_\(provider.rawValue.uppercased())_\(scenario.rawValue.uppercased())"
    }
}

private func safeBudgetMessage(_ error: LiveBudgetError) -> String {
    switch error {
    case .invalidLedger: "INVALID_LEDGER"
    case .providerLimit(let provider, let limit): "PROVIDER_LIMIT_\(provider.rawValue.uppercased())_\(limit)"
    case .totalLimit(let limit): "TOTAL_LIMIT_\(limit)"
    case .persistenceFailed: "PERSISTENCE_FAILED"
    }
}
