import AgentCore
import AgentModels
import AgentProviders
import AgentTools
import Foundation
@testable import WorkspaceAgent
import XCTest

final class WorkspaceAgentTests: XCTestCase {
    func testContentHashMatchesKnownVectors() {
        XCTAssertEqual(
            WorkspaceContentHash.hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            WorkspaceContentHash.hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            WorkspaceContentHash.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
        XCTAssertEqual(
            WorkspaceContentHash.hex("The quick brown fox jumps over the lazy dog"),
            "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
        )
    }

    func testPathParserRejectsTraversalAndKeepsCanonicalIdentity() throws {
        let root = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try WorkspacePath.parse("notes/todo.txt", root: root).relativePath, "notes/todo.txt")
        XCTAssertEqual(try WorkspacePath.parse(".", root: root).relativePath, ".")
        for rejected in ["../secret", "/etc/passwd", "notes/../../passwd", "notes/./todo.txt", "", "~/.ssh", "notes\\todo"] {
            XCTAssertThrowsError(try WorkspacePath.parse(rejected, root: root)) { error in
                XCTAssertEqual(error as? WorkspaceFileError, .rejectedPath(rejected))
            }
        }
    }

    func testListReadAndSearchToolsObserveSandboxFiles() async throws {
        let env = try await makeEnvironment(files: [
            "notes/todo.txt": "buy milk",
            "notes/ideas.txt": "plant trees",
            "readme.txt": "workspace",
        ])
        defer { env.cleanup() }
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1:
                return toolResponse(request, [toolCall("list_files", id: "list", ["path": "notes"])])
            case 2:
                return toolResponse(request, [toolCall("read_file", id: "read", ["path": "notes/todo.txt"])])
            case 3:
                return toolResponse(request, [toolCall("search_files", id: "search", ["query": "trees"])])
            default:
                return textResponse(request, "Listed, read, and searched the workspace.")
            }
        }
        let result = try await run(env, provider: provider, prompt: "Inspect notes")
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.toolCalls, 3)
        XCTAssertEqual(result.response.content, [.text("Listed, read, and searched the workspace.")])
    }

    func testWriteAndMoveUseReceiptsAndUpdateFiles() async throws {
        let env = try await makeEnvironment(files: ["notes/todo.txt": "buy milk"])
        defer { env.cleanup() }
        let originalHash = WorkspaceContentHash.hex("buy milk")
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1:
                return toolResponse(request, [toolCall("read_file", id: "read", ["path": "notes/todo.txt"])])
            case 2:
                return toolResponse(request, [toolCall("write_file", id: "write", [
                    "path": "notes/todo.txt",
                    "content": "buy oat milk",
                    "expectedHash": originalHash,
                ])])
            case 3:
                return toolResponse(request, [toolCall("move_file", id: "move", [
                    "path": "notes/todo.txt",
                    "destination": "notes/errands.txt",
                    "expectedHash": WorkspaceContentHash.hex("buy oat milk"),
                ])])
            default:
                return textResponse(request, "Moved the updated file.")
            }
        }
        let result = try await run(env, provider: provider, prompt: "Update then rename the note")
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.receipts.count, 2)
        XCTAssertEqual(result.receipts[0].effect, .mutation)
        XCTAssertEqual(result.receipts[0].receipt.revision, WorkspaceContentHash.hex("buy oat milk"))
        XCTAssertEqual(result.receipts[1].receipt.revision, WorkspaceContentHash.hex("buy oat milk"))
        XCTAssertEqual(try String(contentsOf: env.root.appendingPathComponent("notes/errands.txt"), encoding: .utf8), "buy oat milk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.root.appendingPathComponent("notes/todo.txt").path))
        let pending = await env.journal.pendingMutations()
        XCTAssertTrue(pending.isEmpty)
    }

    func testCreateFileRequiresDirectoryEvidenceAndWriteReceipt() async throws {
        let env = try await makeEnvironment(files: ["notes/todo.txt": "buy milk"])
        defer { env.cleanup() }
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1:
                return toolResponse(request, [toolCall("list_files", id: "list", ["path": "notes"])])
            case 2:
                return toolResponse(request, [toolCall("write_file", id: "create", [
                    "path": "notes/done.txt",
                    "content": "all done",
                ])])
            default:
                return textResponse(request, "Created done.txt.")
            }
        }
        let result = try await run(env, provider: provider, prompt: "Add a done file")
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.receipts.count, 1)
        XCTAssertEqual(try String(contentsOf: env.root.appendingPathComponent("notes/done.txt"), encoding: .utf8), "all done")
    }

    func testPathTraversalIsRejectedBeforeMutation() async throws {
        let env = try await makeEnvironment(files: ["notes/todo.txt": "buy milk"])
        defer { env.cleanup() }
        let provider = ScriptedProvider { request, _ in
            toolResponse(request, [toolCall("read_file", id: "read", ["path": "../secret.txt"])])
        }
        await assertRunThrows(env, provider: provider, prompt: "Leave the sandbox") { error in
            XCTAssertEqual(error as? WorkspaceFileError, .rejectedPath("../secret.txt"))
        }
        assertEquals(await env.store.mutationCount, 0)
    }

    func testUnknownTargetWithoutEvidenceIsRejected() async throws {
        let env = try await makeEnvironment(files: ["notes/todo.txt": "buy milk"])
        defer { env.cleanup() }
        let provider = ScriptedProvider { request, _ in
            toolResponse(request, [toolCall("write_file", id: "write", [
                "path": "secret.txt",
                "content": "nope",
                "expectedHash": WorkspaceContentHash.hex("missing"),
            ])])
        }
        await assertRunThrows(env, provider: provider, prompt: "Overwrite an unseen file") { error in
            XCTAssertEqual(error as? EvidenceError, .unavailable(.init(namespace: "workspace.file", id: "secret.txt")))
        }
        assertEquals(await env.store.mutationCount, 0)
    }

    func testMutationWithoutRequiredEvidenceIsRejected() async throws {
        let env = try await makeEnvironment(files: ["notes/todo.txt": "buy milk"])
        defer { env.cleanup() }
        let provider = ScriptedProvider { request, turn in
            turn == 1
                ? toolResponse(request, [toolCall("list_files", id: "list", ["path": "notes"])])
                : toolResponse(request, [toolCall("write_file", id: "write", [
                    "path": "notes/todo.txt",
                    "content": "overwrite without a hash",
                ])])
        }
        await assertRunThrows(env, provider: provider, prompt: "Overwrite without a hash") { error in
            XCTAssertEqual(error as? WorkspaceFileError, .missingEvidence("notes/todo.txt"))
        }
        assertEquals(await env.store.mutationCount, 0)
        XCTAssertEqual(try String(contentsOf: env.root.appendingPathComponent("notes/todo.txt"), encoding: .utf8), "buy milk")
    }

    func testStaleEvidenceRejectsWriteAfterExternalChange() async throws {
        let env = try await makeEnvironment(files: ["notes/todo.txt": "buy milk"])
        defer { env.cleanup() }
        let originalHash = WorkspaceContentHash.hex("buy milk")
        let provider = ScriptedProvider { request, turn in
            if turn == 1 {
                return toolResponse(request, [toolCall("read_file", id: "read", ["path": "notes/todo.txt"])])
            }
            try Data("changed outside".utf8).write(to: env.root.appendingPathComponent("notes/todo.txt"))
            return toolResponse(request, [toolCall("write_file", id: "write", [
                "path": "notes/todo.txt",
                "content": "buy oat milk",
                "expectedHash": originalHash,
            ])])
        }
        await assertRunThrows(env, provider: provider, prompt: "Write after an external edit") { error in
            XCTAssertEqual(error as? WorkspaceFileError, .staleEvidence("notes/todo.txt"))
        }
        assertEquals(await env.store.mutationCount, 0)
        XCTAssertEqual(
            try String(contentsOf: env.root.appendingPathComponent("notes/todo.txt"), encoding: .utf8),
            "changed outside"
        )
    }

    func testInvalidReceiptIsRejected() async throws {
        let root = try makeSandbox(["notes/todo.txt": "buy milk"])
        let store = try WorkspaceFileStore(root: root)
        let (journal, journalURL) = try makeJournal()
        let tools: [any AgentTool] = [
            try WorkspaceListFilesTool(store: store),
            try WorkspaceReadFileTool(store: store),
            try WorkspaceSearchFilesTool(store: store),
            try WorkspaceWriteFileTool(store: store) { receipt in
                ToolReceipt(
                    operationID: "wrong-operation",
                    status: receipt.status,
                    confirmedTargets: receipt.confirmedTargets,
                    revision: receipt.revision
                )
            },
            try WorkspaceMoveFileTool(store: store),
        ]
        let originalHash = WorkspaceContentHash.hex("buy milk")
        let provider = ScriptedProvider { request, turn in
            turn == 1
                ? toolResponse(request, [toolCall("read_file", id: "read", ["path": "notes/todo.txt"])])
                : toolResponse(request, [toolCall("write_file", id: "write", [
                    "path": "notes/todo.txt",
                    "content": "buy oat milk",
                    "expectedHash": originalHash,
                ])])
        }
        let host = try WorkspaceAgentHost(
            store: store, provider: provider, model: workspaceModel, journal: journal, tools: tools
        )
        let session = try host.makeSession()
        do {
            _ = try await session.run("Update the note").wait()
            XCTFail("Invalid receipts must fail closed")
        } catch {
            XCTAssertEqual(error as? ToolReceiptError, .operationMismatch)
        }
        let pending = await journal.pendingMutations()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].state, .needsReconciliation)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: journalURL)
    }

    func testReceiptTargetMismatchIsRejected() async throws {
        let root = try makeSandbox(["notes/todo.txt": "buy milk"])
        let store = try WorkspaceFileStore(root: root)
        let (journal, journalURL) = try makeJournal()
        let tools: [any AgentTool] = [
            try WorkspaceListFilesTool(store: store),
            try WorkspaceReadFileTool(store: store),
            try WorkspaceSearchFilesTool(store: store),
            try WorkspaceWriteFileTool(store: store) { receipt in
                ToolReceipt(
                    operationID: receipt.operationID,
                    status: .succeeded,
                    confirmedTargets: [.init(namespace: "workspace.file", id: "other.txt")],
                    revision: receipt.revision
                )
            },
            try WorkspaceMoveFileTool(store: store),
        ]
        let originalHash = WorkspaceContentHash.hex("buy milk")
        let provider = ScriptedProvider { request, turn in
            turn == 1
                ? toolResponse(request, [toolCall("read_file", id: "read", ["path": "notes/todo.txt"])])
                : toolResponse(request, [toolCall("write_file", id: "write", [
                    "path": "notes/todo.txt",
                    "content": "buy oat milk",
                    "expectedHash": originalHash,
                ])])
        }
        let host = try WorkspaceAgentHost(
            store: store, provider: provider, model: workspaceModel, journal: journal, tools: tools
        )
        do {
            _ = try await host.makeSession().run("Update the note").wait()
            XCTFail("Target mismatch must fail closed")
        } catch {
            XCTAssertEqual(error as? ToolReceiptError, .targetsMismatch)
        }
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: journalURL)
    }

    func testDurableIntentIsPersistedBeforeWrite() async throws {
        let env = try await makeEnvironment(files: ["notes/todo.txt": "buy milk"])
        defer { env.cleanup() }
        let originalHash = WorkspaceContentHash.hex("buy milk")
        let provider = ScriptedProvider { request, turn in
            turn == 1
                ? toolResponse(request, [toolCall("read_file", id: "read", ["path": "notes/todo.txt"])])
                : toolResponse(request, [toolCall("write_file", id: "write", [
                    "path": "notes/todo.txt",
                    "content": "buy oat milk",
                    "expectedHash": originalHash,
                ])])
        }
        await env.store.setPreMutationFault {
            let events = await env.journal.snapshot().map(\.event)
            XCTAssertTrue(events.contains { if case .pendingMutation = $0 { true } else { false } })
            throw SimulatedCrash.beforeMutation
        }
        await assertRunThrows(env, provider: provider, prompt: "Update the note") { error in
            XCTAssertTrue(error is SimulatedCrash)
        }
        assertEquals(await env.store.mutationCount, 0)
        let pending = await env.journal.pendingMutations()
        XCTAssertEqual(pending.count, 1)
    }

    func testCrashBeforeSettlementThenRestartDoesNotReplayMutation() async throws {
        let env = try await makeEnvironment(files: ["notes/todo.txt": "buy milk"])
        defer { env.cleanup() }
        let sessionID = UUID()
        let originalHash = WorkspaceContentHash.hex("buy milk")
        let provider = ScriptedProvider { request, turn in
            turn == 1
                ? toolResponse(request, [toolCall("read_file", id: "read", ["path": "notes/todo.txt"])])
                : toolResponse(request, [toolCall("write_file", id: "write", [
                    "path": "notes/todo.txt",
                    "content": "buy oat milk",
                    "expectedHash": originalHash,
                ])])
        }
        await env.store.setPostMutationFault { throw SimulatedCrash.afterMutation }
        let session = try env.host(provider: provider).makeSession(id: sessionID)
        let run = try await session.run("Update the note")
        do {
            _ = try await run.wait()
            XCTFail("Crash after write must not settle")
        } catch {
            XCTAssertTrue(error is SimulatedCrash)
        }
        await session.waitForRunToDrain(runID: run.id)
        assertEquals(await env.store.mutationCount, 1)
        XCTAssertEqual(
            try String(contentsOf: env.root.appendingPathComponent("notes/todo.txt"), encoding: .utf8),
            "buy oat milk"
        )

        let restarted = try AgentJournal.load(from: env.journalURL)
        let recovered = try await restarted.recoverPendingMutations(sessionID: sessionID)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered[0].state, .needsReconciliation)

        await env.store.setPostMutationFault(nil)
        let replay = ScriptedProvider { request, turn in
            switch turn {
            case 1:
                return toolResponse(request, [toolCall("read_file", id: "read-again", ["path": "notes/todo.txt"])])
            case 2:
                return toolResponse(request, [toolCall("write_file", id: "replay", [
                    "path": "notes/todo.txt",
                    "content": "replayed",
                    "expectedHash": WorkspaceContentHash.hex("buy oat milk"),
                ])])
            default:
                return textResponse(request, "Should not finish")
            }
        }
        let replayHost = try WorkspaceAgentHost(
            store: env.store, provider: replay, model: workspaceModel, journal: restarted, scheduler: env.scheduler
        )
        do {
            _ = try await replayHost.makeSession(id: sessionID).run("Try again").wait()
            XCTFail("Restart must not replay a quarantined mutation")
        } catch {
            XCTAssertEqual(error as? AgentJournalError, .mutationRequiresReconciliation)
        }
        assertEquals(await env.store.mutationCount, 1)
        XCTAssertNotEqual(
            try String(contentsOf: env.root.appendingPathComponent("notes/todo.txt"), encoding: .utf8),
            "replayed"
        )
    }

    func testExplicitReconciliationSettlesWithoutReplayingExecutor() async throws {
        let env = try await makeEnvironment(files: ["notes/todo.txt": "buy milk"])
        defer { env.cleanup() }
        let sessionID = UUID()
        let originalHash = WorkspaceContentHash.hex("buy milk")
        let provider = ScriptedProvider { request, turn in
            turn == 1
                ? toolResponse(request, [toolCall("read_file", id: "read", ["path": "notes/todo.txt"])])
                : toolResponse(request, [toolCall("write_file", id: "write", [
                    "path": "notes/todo.txt",
                    "content": "buy oat milk",
                    "expectedHash": originalHash,
                ])])
        }
        await env.store.setPostMutationFault { throw SimulatedCrash.afterMutation }
        let session = try env.host(provider: provider).makeSession(id: sessionID)
        let run = try await session.run("Update the note")
        do { _ = try await run.wait() } catch { XCTAssertTrue(error is SimulatedCrash) }
        await session.waitForRunToDrain(runID: run.id)

        let restarted = try AgentJournal.load(from: env.journalURL)
        let recovered = try await restarted.recoverPendingMutations(sessionID: sessionID)
        let pending = try XCTUnwrap(recovered.first)
        try await restarted.reconcileMutation(
            pending,
            receipt: ToolReceipt(
                operationID: pending.intent.idempotencyKey,
                status: .succeeded,
                confirmedTargets: [.init(namespace: "workspace.file", id: "notes/todo.txt")],
                revision: WorkspaceContentHash.hex("buy oat milk")
            )
        )
        assertTrue(await restarted.pendingMutations().isEmpty)
        assertEquals(await env.store.mutationCount, 1)
    }

    func testConcurrentWritesToTheSameFileAreSerialized() async throws {
        let root = try makeSandbox(["notes/todo.txt": "buy milk"])
        let store = try WorkspaceFileStore(root: root)
        let scheduler = ToolScheduler()
        await store.setMutationHold { try? await Task.sleep(for: .milliseconds(80)) }
        let originalHash = WorkspaceContentHash.hex("buy milk")
        func makeHost(_ content: String) throws -> (WorkspaceAgentHost, AgentJournal, URL) {
            let (journal, url) = try makeJournal()
            let provider = ScriptedProvider { request, turn in
                switch turn {
                case 1:
                    return toolResponse(request, [toolCall("read_file", id: "read", ["path": "notes/todo.txt"])])
                case 2:
                    return toolResponse(request, [toolCall("write_file", id: "write", [
                        "path": "notes/todo.txt",
                        "content": content,
                        "expectedHash": originalHash,
                    ])])
                default:
                    return textResponse(request, "Updated from \(content)")
                }
            }
            let host = try WorkspaceAgentHost(
                store: store, provider: provider, model: workspaceModel, journal: journal, scheduler: scheduler
            )
            return (host, journal, url)
        }
        let first = try makeHost("from-session-a")
        let second = try makeHost("from-session-b")
        async let resultA: Result<AgentLoopResult, Error> = {
            do { return .success(try await first.0.makeSession().run("A").wait()) }
            catch { return .failure(error) }
        }()
        async let resultB: Result<AgentLoopResult, Error> = {
            do { return .success(try await second.0.makeSession().run("B").wait()) }
            catch { return .failure(error) }
        }()
        let outcomes = [await resultA, await resultB]
        let successes = outcomes.compactMap { try? $0.get() }
        XCTAssertEqual(successes.count, 1)
        assertEquals(await store.peakConcurrentMutations, 1)
        assertEquals(await store.mutationCount, 1)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: first.2)
        try? FileManager.default.removeItem(at: second.2)
    }

    func testReadsOfDifferentFilesCanOverlap() async throws {
        let root = try makeSandbox([
            "notes/todo.txt": "buy milk",
            "notes/ideas.txt": "plant trees",
        ])
        let store = try WorkspaceFileStore(root: root)
        let scheduler = ToolScheduler()
        let gate = ManualGate()
        await store.setReadHold { await gate.wait() }
        func host(_ path: String) throws -> WorkspaceAgentHost {
            let (journal, _) = try makeJournal()
            let provider = ScriptedProvider { request, turn in
                turn == 1
                    ? toolResponse(request, [toolCall("read_file", id: path, ["path": path])])
                    : textResponse(request, "Read \(path)")
            }
            return try WorkspaceAgentHost(
                store: store, provider: provider, model: workspaceModel, journal: journal, scheduler: scheduler
            )
        }
        let first = try host("notes/todo.txt")
        let second = try host("notes/ideas.txt")
        async let runA = try first.makeSession().run("A")
        async let runB = try second.makeSession().run("B")
        let startedA = try await runA
        let startedB = try await runB
        for _ in 0..<30 {
            if await store.peakConcurrentReads == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        assertEquals(await store.peakConcurrentReads, 2)
        await gate.open()
        _ = try await startedA.wait()
        _ = try await startedB.wait()
        try? FileManager.default.removeItem(at: root)
    }

    func testProviderCanBeSubstitutedWithoutChangingTools() async throws {
        let root = try makeSandbox(["notes/todo.txt": "buy milk"])
        let store = try WorkspaceFileStore(root: root)
        let tools = try WorkspaceAgentHost.makeTools(store: store)
        let (journal, journalURL) = try makeJournal()
        _ = try WorkspaceAgentHost(
            store: store,
            provider: AnthropicProvider(apiKey: "test-key"),
            model: ModelID(provider: "anthropic", name: "claude-sonnet-4-6"),
            journal: journal,
            tools: tools
        )
        let scripted = ScriptedProvider { request, turn in
            turn == 1
                ? toolResponse(request, [toolCall("read_file", id: "read", ["path": "notes/todo.txt"])])
                : textResponse(request, "Read with a substituted provider.")
        }
        let host = try WorkspaceAgentHost(
            store: store, provider: scripted, model: workspaceModel, journal: journal, tools: tools
        )
        let result = try await host.makeSession().run("Read").wait()
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.response.content, [.text("Read with a substituted provider.")])
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: journalURL)
    }

    func testAnthropicConvenienceConstructionDoesNotNeedAppleProvider() throws {
        let root = try makeSandbox()
        let (journal, journalURL) = try makeJournal()
        _ = try WorkspaceAgentHost.anthropic(root: root, apiKey: "test-key", journal: journal)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: journalURL)
    }

    func testCoreSourcesDoNotGainWorkspaceDomainTypes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for module in ["AgentCore", "AgentModels", "AgentTools"] {
            let files = try swiftSources(in: root.appendingPathComponent("Sources/\(module)"))
            XCTAssertFalse(files.isEmpty, module)
            for url in files {
                let source = try String(contentsOf: url, encoding: .utf8)
                XCTAssertFalse(source.contains("WorkspacePath"), url.path)
                XCTAssertFalse(source.contains("workspace.file"), url.path)
                XCTAssertFalse(source.contains("workspace.dir"), url.path)
                XCTAssertFalse(source.contains("WorkspaceAgent"), url.path)
            }
        }
    }

    func testHostSourcesDoNotDependOnOtohaOrAppleOnDeviceProvider() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/WorkspaceAgent")
        let files = try swiftSources(in: root)
        XCTAssertFalse(files.isEmpty)
        let forbidden = ["Otoha", "Tingting", "AppleMusic", "MusicKit", "AVFoundation", "SwiftUI", "Observation", "StoreKit", "AgentAppleProvider"]
        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(source.contains(token), "\(url.lastPathComponent) contains \(token)")
            }
            if url.lastPathComponent != "WorkspaceAgentHost.swift" {
                XCTAssertFalse(
                    source.contains("import AgentProviders"),
                    "\(url.lastPathComponent) must not import a provider implementation"
                )
            }
        }
    }

    private func swiftSources(in directory: URL) throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ))
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }
}

private struct WorkspaceTestEnvironment {
    let root: URL
    let store: WorkspaceFileStore
    let journal: AgentJournal
    let journalURL: URL
    let scheduler: ToolScheduler
    let tools: [any AgentTool]?

    func host(provider: any ModelProvider) throws -> WorkspaceAgentHost {
        try WorkspaceAgentHost(
            store: store,
            provider: provider,
            model: workspaceModel,
            journal: journal,
            scheduler: scheduler,
            tools: tools
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: journalURL)
    }
}

private extension WorkspaceAgentTests {
    func makeEnvironment(files: [String: String], tools: [any AgentTool]? = nil) async throws -> WorkspaceTestEnvironment {
        let root = try makeSandbox(files)
        let store = try WorkspaceFileStore(root: root)
        let (journal, journalURL) = try makeJournal()
        return WorkspaceTestEnvironment(
            root: root, store: store, journal: journal, journalURL: journalURL,
            scheduler: ToolScheduler(), tools: tools
        )
    }

    func run(_ env: WorkspaceTestEnvironment, provider: ScriptedProvider, prompt: String) async throws -> AgentLoopResult {
        try await env.host(provider: provider).makeSession().run(prompt).wait()
    }

    func assertRunThrows(
        _ env: WorkspaceTestEnvironment,
        provider: ScriptedProvider,
        prompt: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ check: (any Error) -> Void
    ) async {
        do {
            _ = try await run(env, provider: provider, prompt: prompt)
            XCTFail("Expected the run to fail", file: file, line: line)
        } catch {
            check(error)
        }
    }

    func assertEquals<T: Equatable>(
        _ actual: T,
        _ expected: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func assertTrue(_ actual: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(actual, file: file, line: line)
    }
}
