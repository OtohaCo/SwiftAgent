import AgentCore
import AgentModels
import AgentProviders
import AgentTools
import Foundation
@testable import WorkspaceAgent
import XCTest

final class WorkspaceFileRaceTests: XCTestCase {
    func testExternalProcessChangeAfterHashCheckDoesNotSucceed() async throws {
        let root = try makeSandbox(["notes/todo.txt": "buy milk"])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceFileStore(root: root)
        let barrier = RaceBarrier()
        await store.setAfterPreconditionHold { await barrier.waitForOperation() }
        let originalHash = WorkspaceContentHash.hex("buy milk")
        let write = Task {
            try await store.write(
                path: "notes/todo.txt",
                content: "buy oat milk",
                expectedHash: originalHash
            )
        }
        await barrier.waitUntilReached()
        let pid = try writeFromAnotherProcess(
            to: root.appendingPathComponent("notes/todo.txt"),
            content: "stolen-by-process"
        )
        XCTAssertNotEqual(pid, 0)
        XCTAssertNotEqual(pid, ProcessInfo.processInfo.processIdentifier)
        await barrier.release()
        do {
            _ = try await write.value
            XCTFail("A lost hash race must not return a revision")
        } catch {
            XCTAssertEqual(error as? WorkspaceFileError, .staleEvidence("notes/todo.txt"))
        }
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("notes/todo.txt"), encoding: .utf8),
            "stolen-by-process"
        )
        assertEquals(await store.mutationCount, 0)
    }

    func testExternalProcessCreateAfterNotExistsCheckDoesNotOverwrite() async throws {
        let root = try makeSandbox(["notes/todo.txt": "buy milk"])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceFileStore(root: root)
        let barrier = RaceBarrier()
        await store.setAfterPreconditionHold { await barrier.waitForOperation() }
        let write = Task {
            try await store.write(path: "notes/done.txt", content: "from-agent", expectedHash: nil)
        }
        await barrier.waitUntilReached()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes/done.txt").path))
        let pid = try writeFromAnotherProcess(
            to: root.appendingPathComponent("notes/done.txt"),
            content: "stolen-create"
        )
        XCTAssertNotEqual(pid, ProcessInfo.processInfo.processIdentifier)
        await barrier.release()
        do {
            _ = try await write.value
            XCTFail("A create race must not overwrite the stolen file")
        } catch {
            XCTAssertEqual(error as? WorkspaceFileError, .alreadyExists("notes/done.txt"))
        }
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("notes/done.txt"), encoding: .utf8),
            "stolen-create"
        )
        assertEquals(await store.mutationCount, 0)
    }

    func testMoveDestinationCreatedAfterCheckDoesNotClobber() async throws {
        let root = try makeSandbox(["notes/todo.txt": "buy milk"])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceFileStore(root: root)
        let barrier = RaceBarrier()
        await store.setAfterPreconditionHold { await barrier.waitForOperation() }
        let move = Task {
            try await store.move(
                from: "notes/todo.txt",
                to: "notes/errands.txt",
                expectedHash: WorkspaceContentHash.hex("buy milk")
            )
        }
        await barrier.waitUntilReached()
        _ = try writeFromAnotherProcess(
            to: root.appendingPathComponent("notes/errands.txt"),
            content: "already-there"
        )
        await barrier.release()
        do {
            _ = try await move.value
            XCTFail("Move must not replace a destination that appeared after the check")
        } catch {
            XCTAssertEqual(error as? WorkspaceFileError, .alreadyExists("notes/errands.txt"))
        }
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("notes/todo.txt"), encoding: .utf8),
            "buy milk"
        )
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("notes/errands.txt"), encoding: .utf8),
            "already-there"
        )
        assertEquals(await store.mutationCount, 0)
    }

    func testParentReplacedWithSymlinkAfterCheckIsRejected() async throws {
        let root = try makeSandbox(["notes/todo.txt": "buy milk"])
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceOutside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("escaped".utf8).write(to: outside.appendingPathComponent("todo.txt"))
        let store = try WorkspaceFileStore(root: root)
        let barrier = RaceBarrier()
        await store.setAfterPreconditionHold { await barrier.waitForOperation() }
        let write = Task {
            try await store.write(
                path: "notes/todo.txt",
                content: "buy oat milk",
                expectedHash: WorkspaceContentHash.hex("buy milk")
            )
        }
        await barrier.waitUntilReached()
        try replaceWithSymlinkFromAnotherProcess(
            at: root.appendingPathComponent("notes"),
            destination: outside
        )
        await barrier.release()
        do {
            _ = try await write.value
            XCTFail("A symlink swap after the check must not succeed")
        } catch {
            XCTAssertEqual(error as? WorkspaceFileError, .rejectedPath(root.appendingPathComponent("notes").path))
        }
        assertEquals(await store.mutationCount, 0)
    }

    func testAgentWriteRaceLeavesReconciliationAndNoSuccessReceipt() async throws {
        let env = try makeAgentEnvironment(files: ["notes/todo.txt": "buy milk"])
        defer { env.cleanup() }
        let originalHash = WorkspaceContentHash.hex("buy milk")
        let barrier = RaceBarrier()
        await env.store.setAfterPreconditionHold { await barrier.waitForOperation() }
        let provider = ScriptedProvider { request, turn in
            turn == 1
                ? toolResponse(request, [toolCall("read_file", id: "read", ["path": "notes/todo.txt"])])
                : toolResponse(request, [toolCall("write_file", id: "write", [
                    "path": "notes/todo.txt",
                    "content": "buy oat milk",
                    "expectedHash": originalHash,
                ])])
        }
        let session = try env.host(provider: provider).makeSession()
        let run = try await session.run("Update the note")
        await barrier.waitUntilReached()
        _ = try writeFromAnotherProcess(
            to: env.root.appendingPathComponent("notes/todo.txt"),
            content: "stolen-by-process"
        )
        await barrier.release()
        do {
            _ = try await run.wait()
            XCTFail("The raced write must not settle")
        } catch {
            XCTAssertEqual(error as? WorkspaceFileError, .staleEvidence("notes/todo.txt"))
        }
        let pending = await env.journal.pendingMutations()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].state, .needsReconciliation)
        let events = await env.journal.snapshot().map(\.event)
        XCTAssertFalse(events.contains { if case .mutationSettled = $0 { true } else { false } })
        XCTAssertEqual(
            try String(contentsOf: env.root.appendingPathComponent("notes/todo.txt"), encoding: .utf8),
            "stolen-by-process"
        )
    }

    private func makeAgentEnvironment(files: [String: String]) throws -> WorkspaceTestEnvironment {
        let root = try makeSandbox(files)
        let store = try WorkspaceFileStore(root: root)
        let (journal, journalURL) = try makeJournal()
        return WorkspaceTestEnvironment(
            root: root, store: store, journal: journal, journalURL: journalURL,
            scheduler: ToolScheduler(), tools: nil
        )
    }

    private func assertEquals<T: Equatable>(
        _ actual: T,
        _ expected: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}
