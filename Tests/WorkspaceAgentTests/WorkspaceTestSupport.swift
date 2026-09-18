import AgentCore
import AgentModels
import AgentProviders
import AgentTools
import Foundation
import WorkspaceAgent

let workspaceModel = ModelID(provider: "fixture", name: "workspace")

struct ScriptedProvider: ModelProvider {
    var descriptor = ModelProviderDescriptor(
        id: "fixture",
        capabilities: [.streaming, .multiTurn, .tools, .structuredOutput]
    )
    let log = RequestLog()
    let respond: @Sendable (ModelRequest, Int) async throws -> [ModelEvent]

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let turn = await log.record()
            for event in try await respond(request, turn) { try emit(event) }
        }
    }
}

actor RequestLog {
    private var count = 0
    func record() -> Int {
        count += 1
        return count
    }
}

func textResponse(_ request: ModelRequest, _ text: String) -> [ModelEvent] {
    let info = ResponseInfo(id: "response", model: request.model)
    return [
        .responseStarted(info),
        .textDelta(text),
        .responseCompleted(.init(info: info, content: [.text(text)], stopReason: .endTurn)),
    ]
}

func toolResponse(_ request: ModelRequest, _ calls: [ToolCall]) -> [ModelEvent] {
    let info = ResponseInfo(id: "response", model: request.model)
    var events: [ModelEvent] = [.responseStarted(info)]
    for call in calls {
        events.append(.toolCallStarted(call.id, name: call.name))
        events.append(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
        events.append(.toolCallCompleted(call))
    }
    events.append(.responseCompleted(.init(info: info, toolCalls: calls, stopReason: .toolCalls)))
    return events
}

func encodeJSON(_ object: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
}

func toolCall(_ name: String, id: String, _ arguments: [String: Any]) -> ToolCall {
    .init(id: .init(rawValue: id), name: name, argumentsJSON: encodeJSON(arguments), completeness: .complete)
}

func makeSandbox(_ files: [String: String] = [:]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceAgent-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, content) in files {
        let url = path.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
    return root
}

func makeJournal() throws -> (AgentJournal, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceJournal-\(UUID().uuidString).log")
    return (try AgentJournal(persistenceURL: url), url)
}

actor ManualGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { waiters.append(continuation) }
        }
    }

    func open() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

actor RaceBarrier {
    private var reached = false
    private var reachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForOperation() async {
        reached = true
        let waiting = reachedWaiters
        reachedWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
        if released { return }
        await withCheckedContinuation { holdWaiters.append($0) }
    }

    func waitUntilReached() async {
        if reached { return }
        await withCheckedContinuation { reachedWaiters.append($0) }
    }

    func release() {
        released = true
        let waiting = holdWaiters
        holdWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

func writeFromAnotherProcess(to url: URL, content: String) throws -> Int32 {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "printf '%s' \"$1\" > \"$2\"", "workspace-external-writer", content, url.path]
    try process.run()
    let pid = process.processIdentifier
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw FixtureProcessError.nonzeroStatus(process.terminationStatus)
    }
    return pid
}

func replaceWithSymlinkFromAnotherProcess(at url: URL, destination: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
        "-c",
        "rm -rf \"$1\" && ln -s \"$2\" \"$1\"",
        "workspace-external-symlink",
        url.path,
        destination.path,
    ]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw FixtureProcessError.nonzeroStatus(process.terminationStatus)
    }
}

func moveAsideAndReplaceWithSymlinkFromAnotherProcess(at url: URL, destination: URL, backup: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
        "-c",
        "mkdir -p \"$(dirname \"$3\")\" && mv \"$1\" \"$3\" && ln -s \"$2\" \"$1\"",
        "workspace-root-symlink",
        url.path,
        destination.path,
        backup.path,
    ]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw FixtureProcessError.nonzeroStatus(process.terminationStatus)
    }
}

enum FixtureProcessError: Error { case nonzeroStatus(Int32) }

enum SimulatedCrash: Error { case beforeMutation, afterMutation }
