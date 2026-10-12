import AgentModels
import Foundation
import Testing
@testable import AgentCore

@Suite struct NativeMaintenanceDeadlineTests {
    @Test(arguments: ["compaction", "pause_turn"])
    func maintenanceMustNotSettleFinalAnswerGate(reason: String) async throws {
        let gate = OperationDeadlineGate(deadline: .now.advanced(by: .seconds(3)))
        let info = ResponseInfo(id: "maintenance", model: .init(provider: "fixture", name: "model"))
        let upstream = AsyncThrowingStream<ModelEvent, Error> { c in
            c.yield(.responseStarted(info))
            c.yield(.responseCompleted(.init(info: info, stopReason: .unknown(reason))))
            c.finish()
        }
        var count = 0
        for try await _ in settlingModelEvents(upstream, gate: gate) { count += 1 }
        #expect(count == 2)
        #expect(!gate.isSettled)
    }
}
