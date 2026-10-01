import AgentModels
import AgentTools
import Foundation

public enum AgentCapabilityError: Error, Equatable, Sendable {
    case invalidIdentity(String)
    case duplicateToolIdentity
    case duplicateToolName
    case invalidResourceScope
    case sessionMismatch
    case revoked
    case resourceOutsideScope
}

/// Host-owned implementation and version, captured once by a Run binding.
public struct AgentCapabilityTool: Sendable {
    public let id: String
    public let version: String
    public let tool: any AgentTool
    /// `.deferred` binds the tool without sending its definition to the model until a tool result
    /// of the Run declares it. Either way it is part of the binding's reach and resource scope.
    public let exposure: ToolExposure

    public init(id: String, version: String, tool: any AgentTool, exposure: ToolExposure = .declared) {
        self.id = id
        self.version = version
        self.tool = tool
        self.exposure = exposure
    }
}

/// Diagnostic metadata alone can never recreate the execution handle.
public struct AgentCapabilityInfo: Codable, Equatable, Sendable {
    public struct Tool: Codable, Equatable, Sendable {
        public let id: String
        public let version: String
        public let name: String
        public let effect: ToolPolicy.Effect
        /// Encoded only when `.deferred`, so a binding without deferred tools encodes as before;
        /// a value without it decodes as `.declared`.
        public let exposure: ToolExposure

        init(id: String, version: String, name: String, effect: ToolPolicy.Effect, exposure: ToolExposure) {
            self.id = id
            self.version = version
            self.name = name
            self.effect = effect
            self.exposure = exposure
        }

        private enum CodingKeys: String, CodingKey { case id, version, name, effect, exposure }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            version = try container.decode(String.self, forKey: .version)
            name = try container.decode(String.self, forKey: .name)
            effect = try container.decode(ToolPolicy.Effect.self, forKey: .effect)
            exposure = try container.decodeIfPresent(ToolExposure.self, forKey: .exposure) ?? .declared
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(version, forKey: .version)
            try container.encode(name, forKey: .name)
            try container.encode(effect, forKey: .effect)
            if exposure != .declared { try container.encode(exposure, forKey: .exposure) }
        }
    }

    public let identity: String
    public let version: String
    public let scopeID: String
    public let scopeInstanceID: UUID
    public let sessionID: UUID
    public let runID: UUID?
    public let backendInstanceID: String
    public let backendVersion: String
    public let tools: [Tool]
    public let allowedResourceCount: Int
    public let capturedGeneration: UInt64

    package func forRun(_ runID: UUID) -> Self {
        .init(identity: identity, version: version, scopeID: scopeID,
              scopeInstanceID: scopeInstanceID, sessionID: sessionID, runID: runID,
              backendInstanceID: backendInstanceID, backendVersion: backendVersion,
              tools: tools, allowedResourceCount: allowedResourceCount,
              capturedGeneration: capturedGeneration)
    }
}

public struct AgentCapabilityStatus: Codable, Equatable, Sendable {
    public let scopeInstanceID: UUID
    public let generation: UInt64
    public let revoked: Bool
    public let activeRuns: Int
    public let activeAdmissions: Int
    /// Final admission is not proof of executor entry or an external effect.
    public let finalAdmissions: UInt64
}

/// Immutable registry plus live scope owner. Only `AgentSession` can construct
/// this value, binding it to that particular Session instance.
public struct AgentCapabilityBinding: Sendable {
    public let info: AgentCapabilityInfo
    package let registry: ToolRegistry
    package let scope: AgentCapabilityScope
    package let sessionInstanceID: UUID
    package let allowedResources: Set<ToolResource>

    package init(sessionID: UUID, sessionInstanceID: UUID, identity: String,
                 version: String, scopeID: String?, backendInstanceID: String,
                 backendVersion: String, allowedResources: [ToolResource],
                 tools: [AgentCapabilityTool]) throws {
        let resolvedScopeID = scopeID ?? UUID().uuidString
        for (field, value) in [("identity", identity), ("version", version),
                               ("scopeID", resolvedScopeID), ("backendInstanceID", backendInstanceID),
                               ("backendVersion", backendVersion)] where !Self.valid(value) {
            throw AgentCapabilityError.invalidIdentity(field)
        }
        if !tools.isEmpty || !allowedResources.isEmpty {
            do { try ToolResource.validate(allowedResources) }
            catch { throw AgentCapabilityError.invalidResourceScope }
        }
        var toolIDs = Set<String>()
        var names = Set<String>()
        var descriptors: [AgentCapabilityInfo.Tool] = []
        var erased: [AnyAgentTool] = []
        var deferred = Set<String>()
        for entry in tools {
            guard Self.valid(entry.id), Self.valid(entry.version) else {
                throw AgentCapabilityError.invalidIdentity("tool")
            }
            guard toolIDs.insert(entry.id).inserted else { throw AgentCapabilityError.duplicateToolIdentity }
            // Known by its definition, read once: a tool defined at runtime has no name of its type.
            let tool = try AnyAgentTool(entry.tool)
            guard names.insert(tool.definition.name).inserted else { throw AgentCapabilityError.duplicateToolName }
            descriptors.append(.init(id: entry.id, version: entry.version, name: tool.definition.name,
                                     effect: tool.policy.effect, exposure: entry.exposure))
            erased.append(tool)
            if entry.exposure == .deferred { deferred.insert(tool.definition.name) }
        }
        registry = try ToolRegistry(tools: erased, deferred: deferred)
        let instance = UUID()
        info = .init(identity: identity, version: version, scopeID: resolvedScopeID,
                     scopeInstanceID: instance, sessionID: sessionID, runID: nil,
                     backendInstanceID: backendInstanceID, backendVersion: backendVersion,
                     tools: descriptors.sorted { $0.name < $1.name },
                     allowedResourceCount: allowedResources.count, capturedGeneration: 0)
        self.sessionInstanceID = sessionInstanceID
        self.allowedResources = Set(allowedResources)
        scope = AgentCapabilityScope(instanceID: instance, sessionID: sessionID,
                                     sessionInstanceID: sessionInstanceID,
                                     resources: Set(allowedResources))
    }

    public func revoke() async { await scope.revoke() }
    public func waitForDrain() async throws { try await scope.waitForDrain() }
    public func status() async -> AgentCapabilityStatus { await scope.status() }

    private static func valid(_ value: String) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.isEmpty && value.utf8.count <= 128
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// This actor's synchronous state transitions linearize final admission and
/// revoke. Neither operation holds a lock through Host or storage work.
package actor AgentCapabilityScope: ToolExecutionAdmission {
    package nonisolated var scopeInstanceID: UUID? { instanceID }
    private let instanceID: UUID
    private let sessionID: UUID
    private let sessionInstanceID: UUID
    private let resources: Set<ToolResource>
    private var generation: UInt64 = 0
    private var revoked = false
    private var runs: [UUID: @Sendable () async -> Void] = [:]
    private var admitted: [UUID: UUID] = [:]
    private var admissions: UInt64 = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var waiterCountObservers: [(Int, CheckedContinuation<Void, Never>)] = []

    package init(instanceID: UUID, sessionID: UUID, sessionInstanceID: UUID,
                 resources: Set<ToolResource>) {
        self.instanceID = instanceID
        self.sessionID = sessionID
        self.sessionInstanceID = sessionInstanceID
        self.resources = resources
    }

    package func register(runID: UUID, sessionID: UUID, sessionInstanceID: UUID,
                          cancel: @escaping @Sendable () async -> Void) throws {
        try Task.checkCancellation()
        guard self.sessionID == sessionID, self.sessionInstanceID == sessionInstanceID else {
            throw AgentCapabilityError.sessionMismatch
        }
        guard !revoked, generation == 0 else { throw AgentCapabilityError.revoked }
        guard runs[runID] == nil else { throw AgentCapabilityError.sessionMismatch }
        runs[runID] = cancel
    }

    package func releaseRun(_ runID: UUID) {
        runs.removeValue(forKey: runID)
        notifyDrained()
    }

    package func check(runID: UUID, resources: [ToolResource]) throws {
        try Task.checkCancellation()
        guard runs[runID] != nil, !revoked, generation == 0 else {
            throw AgentCapabilityError.revoked
        }
        guard Set(resources).isSubset(of: self.resources) else {
            throw AgentCapabilityError.resourceOutsideScope
        }
    }

    package func checkRun(_ runID: UUID) throws {
        guard runs[runID] != nil, !revoked, generation == 0 else {
            throw AgentCapabilityError.revoked
        }
    }

    package func admit(runID: UUID, resources: [ToolResource]) throws -> UUID {
        try check(runID: runID, resources: resources)
        let ticket = UUID()
        admitted[ticket] = runID
        admissions += 1
        return ticket
    }

    package func release(_ ticket: UUID) {
        admitted.removeValue(forKey: ticket)
        notifyDrained()
    }

    public func revoke() async {
        guard !revoked else { return }
        revoked = true
        generation += 1
        let cancellations = Array(runs.values)
        for cancel in cancellations { await cancel() }
    }

    public func status() -> AgentCapabilityStatus {
        .init(scopeInstanceID: instanceID, generation: generation, revoked: revoked,
              activeRuns: runs.count, activeAdmissions: admitted.count, finalAdmissions: admissions)
    }

    public func waitForDrain() async throws {
        try Task.checkCancellation()
        guard !runs.isEmpty || !admitted.isEmpty else { return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else if runs.isEmpty && admitted.isEmpty { continuation.resume() }
                else {
                    waiters[id] = continuation
                    notifyWaiterCountObservers()
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id) }
        })
        try Task.checkCancellation()
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        notifyWaiterCountObservers()
    }

    package func waitUntilWaiterCount(_ expected: Int) async {
        if waiters.count == expected { return }
        await withCheckedContinuation { waiterCountObservers.append((expected, $0)) }
    }

    private func notifyWaiterCountObservers() {
        let count = waiters.count
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for observer in waiterCountObservers {
            if observer.0 == count { observer.1.resume() }
            else { remaining.append(observer) }
        }
        waiterCountObservers = remaining
    }

    private func notifyDrained() {
        guard runs.isEmpty, admitted.isEmpty else { return }
        let pending = waiters
        waiters.removeAll()
        notifyWaiterCountObservers()
        pending.values.forEach { $0.resume() }
    }
}
