import Foundation
import LiveProviderSupport
import Testing

struct LiveRequestBudgetTests {
    @Test func budgetPersistsAcrossIndependentInstances() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftagent-live-budget-")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let first = try LiveRequestBudget(fileURL: file, perProviderLimit: 2, totalLimit: 3)

        try await first.reserve(.openAI)
        try await first.reserve(.openAI)
        await #expect(throws: LiveBudgetError.providerLimit(provider: .openAI, limit: 2)) {
            try await first.reserve(.openAI)
        }

        let reloaded = try LiveRequestBudget(fileURL: file, perProviderLimit: 2, totalLimit: 3)
        let snapshot = await reloaded.snapshot()
        #expect(snapshot.totalAttempts == 2)
        #expect(snapshot.attempts[.openAI] == 2)
        try await reloaded.reserve(.anthropic)
        await #expect(throws: LiveBudgetError.totalLimit(limit: 3)) {
            try await reloaded.reserve(.deepSeek)
        }
    }

    @Test func concurrentReservationsCannotExceedTheLimit() async throws {
        let budget = try LiveRequestBudget(fileURL: nil, perProviderLimit: 1, totalLimit: 1)
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do { try await budget.reserve(.openAI); return true }
                    catch { return false }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        #expect(outcomes.filter { $0 }.count == 1)
    }
}
