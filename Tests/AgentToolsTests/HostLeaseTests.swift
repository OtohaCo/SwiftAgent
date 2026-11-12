import AgentTools
import Foundation
import Testing

/// A Host's own operation can hold a scheduler lease (`ToolScheduler.withLease`), so work outside a Run that touches
/// what tools name keeps out, and waits for, the calls it conflicts with.
struct HostLeaseTests {
    private let folder = ToolResource.named(.init(namespace: "workspace", id: "a"))
    private let other = ToolResource.named(.init(namespace: "workspace", id: "b"))

    @Test func aChangeWaitsForAConflictingLeaseAndDisjointWorkDoesNot() async throws {
        let scheduler = ToolScheduler()
        let entered = Signal(), release = Signal()
        let holder = Task {
            try await scheduler.withLease(on: [folder], effect: .mutation) {
                await entered.open()
                await release.wait()
                return "first"
            }
        }
        await entered.wait()
        await #expect(throws: ToolSchedulerError.deadlineExceeded) {
            try await scheduler.withLease(on: [folder], effect: .mutation, until: .now.advanced(by: .milliseconds(80))) { "never" }
        }
        await #expect(throws: ToolSchedulerError.deadlineExceeded) {
            try await scheduler.withLease(on: [folder], effect: .readOnly, until: .now.advanced(by: .milliseconds(80))) { "never" }
        }
        #expect(try await scheduler.withLease(on: [other], effect: .mutation) { "beside" } == "beside")
        await release.open()
        #expect(try await holder.value == "first")
        #expect(try await scheduler.withLease(on: [folder], effect: .mutation, until: .now.advanced(by: .seconds(5))) { "after" } == "after")
    }

    @Test func readsShareALeaseAndAFailedBodyReleasesIt() async throws {
        let scheduler = ToolScheduler()
        let entered = Signal(), release = Signal()
        let reader = Task {
            try await scheduler.withLease(on: [folder], effect: .readOnly) { await entered.open(); await release.wait() }
        }
        await entered.wait()
        try await scheduler.withLease(on: [folder], effect: .readOnly, until: .now.advanced(by: .seconds(5))) {}
        await release.open()
        try await reader.value
        struct Failure: Error {}
        await #expect(throws: Failure.self) { try await scheduler.withLease(on: [.global], effect: .mutation) { throw Failure() } }
        try await scheduler.withLease(on: [folder], effect: .mutation, until: .now.advanced(by: .seconds(5))) {}
    }
}

private actor Signal {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
