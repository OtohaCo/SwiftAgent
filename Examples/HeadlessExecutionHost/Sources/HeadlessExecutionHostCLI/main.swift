import Foundation
import HeadlessExecutionHost

@main
struct HeadlessExecutionHostCLI {
    static func main() async {
        let scenario = CommandLine.arguments.dropFirst().compactMap(HeadlessScenario.init(rawValue:)).first
            ?? .failureAfterWrite
        do {
            let result = try await HeadlessExecutionHost().run(scenario)
            print("scenario=\(result.scenario.rawValue)")
            print("runtime=\(String(describing: result.report.runtimeTermination))")
            print("receipts=\(result.report.receipts.count)")
            print("coverageComplete=\(result.report.coverage.isComplete)")
            print("executorEntries=\(result.executorEntryCount)")
            print("replayExecutorEntries=\(result.replayExecutorEntryCount.map(String.init) ?? "unknown")")
            print("fileContent=\(result.fileContent ?? "unknown")")
        } catch {
            print("headless execution failed: \(error)")
            exit(1)
        }
    }
}
