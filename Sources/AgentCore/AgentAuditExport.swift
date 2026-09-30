import AgentModels
import Foundation

/// Implement reception, authentication, durable acceptance and deduplication in the Host.
/// Receipt of a batch or its ACK grants no execution permission.
public protocol AuditExportSink: Sendable {
    func write(_ batch: AuditExportBatch) async throws -> AuditExportAcknowledgement
}

/// Deterministic transformation of the SDK's conservative export view. Throwing stops export.
/// Change redactionVersion whenever this implementation or its configuration changes.
public protocol AuditExportRedactor: Sendable {
    func redact(_ record: AuditExportRecord) throws -> JSONValue
}

public struct AuditExportRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let storeID: UUID
    public let auditRecordID: UUID
    public let sequence: UInt64
    public let committedDigest: String
    /// Conservative data: UUID associations, fact kind, decision outcome/type and action digest.
    /// Raw arguments, outputs, Receipt identities, Host strings and endpoints are excluded.
    public let view: JSONValue
}

public struct AuditExportBatch: Codable, Equatable, Sendable {
    public let version: Int
    public let exporterID: UUID
    public let batchID: UUID
    public let storeID: UUID
    public let destinationID: String
    public let configurationDigest: String
    public let contentVersion: String
    public let contentDigest: String
    public let firstSequence: UInt64
    public let throughSequence: UInt64
    public let highWaterSequence: UInt64
    public let records: [AuditExportRecord]

    /// Structured archive lines. This is not a complete Journal backup.
    public func jsonlData() throws -> Data {
        var result = Data()
        for record in records { result.append(try AuditEncoding.encode(record)); result.append(0x0A) }
        return result
    }
}

public struct AuditExportAcknowledgement: Codable, Equatable, Sendable {
    public let version: Int
    public let exporterID: UUID
    public let batchID: UUID
    public let storeID: UUID
    public let destinationID: String
    public let configurationDigest: String
    public let contentVersion: String
    public let contentDigest: String
    /// Receiver guarantees durable acceptance of this batch's contiguous prefix.
    public let throughSequence: UInt64
    public init(batch: AuditExportBatch, throughSequence: UInt64? = nil) {
        version = 1; exporterID = batch.exporterID; batchID = batch.batchID; storeID = batch.storeID
        destinationID = batch.destinationID; configurationDigest = batch.configurationDigest
        contentVersion = batch.contentVersion; contentDigest = batch.contentDigest
        self.throughSequence = throughSequence ?? batch.throughSequence
    }
}

public struct AuditExportConfiguration: Sendable {
    public let id: String
    public let destinationID: String
    public let contentVersion: String
    public let redactionVersion: String
    public let query: AuditQuery
    public let pageSize: Int
    public let maximumAttempts: Int
    public let retryDelay: Duration
    public let sinkTimeout: Duration
    public init(id: String, destinationID: String, contentVersion: String, redactionVersion: String,
                query: AuditQuery = .init(), pageSize: Int = 50, maximumAttempts: Int = 3,
                retryDelay: Duration = .seconds(1), sinkTimeout: Duration = .seconds(30)) {
        self.id = id; self.destinationID = destinationID; self.contentVersion = contentVersion
        self.redactionVersion = redactionVersion; self.query = query; self.pageSize = pageSize
        self.maximumAttempts = maximumAttempts; self.retryDelay = retryDelay; self.sinkTimeout = sinkTimeout
    }
    package func digestBytes() throws -> Data {
        struct Identity: Codable { let version: Int; let id: String; let destination: String; let content: String; let redaction: String; let query: AuditQuery }
        guard [id, destinationID, contentVersion, redactionVersion].allSatisfy(AuditEncoding.identifier),
              (1...50).contains(pageSize), (1...8).contains(maximumAttempts), retryDelay >= .zero,
              sinkTimeout > .zero else { throw AgentAuthorizationError.invalidConfiguration }
        return try AuditEncoding.encode(Identity(version: 1, id: id, destination: destinationID,
            content: contentVersion, redaction: redactionVersion, query: query))
    }
}

public struct AuditExportStatus: Sendable, Equatable {
    public let exporterID: UUID
    public let stopped: Bool
    public let physicallyDrained: Bool
    public let acknowledgedThroughSequence: UInt64
    public let observedHighWaterSequence: UInt64
    public let batchesAttempted: UInt64
    public let lastFailure: AgentAuthorizationError?
    /// Preserve a typed local publication failure, including commitUnknown requiring reopen.
    public let journalFailure: AgentJournalError?
    public var backlogRecords: UInt64 { observedHighWaterSequence - min(acknowledgedThroughSequence, observedHighWaterSequence) }
}

/// Explicit exporter owner. Exports the backlog until caught up, stopped, or bounded retries fail.
/// Starting another pass is explicit. Stop cancels outstanding work without requiring full export.
public actor AuditExporter {
    public nonisolated let id: UUID
    private let journal: AgentJournal
    private let configuration: AuditExportConfiguration
    private let configurationDigest: String
    private let sink: any AuditExportSink
    private let redactor: (any AuditExportRedactor)?
    private let work = AgentAuditWorkDrain()
    private let drain = AgentRunDrain()
    private var worker: Task<Void, Never>?
    private var stopped = false
    private var drained = false
    private var acknowledged: UInt64
    private var highWater: UInt64
    private var attempts: UInt64 = 0
    private var failure: AgentAuthorizationError?
    private var journalFailure: AgentJournalError?

    init(id: UUID, journal: AgentJournal, configuration: AuditExportConfiguration, digest: String,
         sink: any AuditExportSink, redactor: (any AuditExportRedactor)?, acknowledged: UInt64, highWater: UInt64) {
        self.id = id; self.journal = journal; self.configuration = configuration; configurationDigest = digest
        self.sink = sink; self.redactor = redactor; self.acknowledged = acknowledged; self.highWater = highWater
    }

    func start() { worker = Task { await self.pump() } }
    public func stop() { stopped = true; worker?.cancel() }
    public func waitForDrain() async throws { try await drain.wait() }
    public func status() -> AuditExportStatus {
        .init(exporterID: id, stopped: stopped, physicallyDrained: drained,
              acknowledgedThroughSequence: acknowledged, observedHighWaterSequence: highWater,
              batchesAttempted: attempts, lastFailure: failure, journalFailure: journalFailure)
    }

    private func pump() async {
        do {
            while !stopped {
                try Task.checkCancellation()
                let page = try await journal.auditRecords(matching: configuration.query,
                    afterExclusiveSequence: acknowledged, limit: configuration.pageSize)
                highWater = page.highWaterSequence
                guard page.scannedThroughSequence > acknowledged else { break }
                let records = try page.records.map { record -> AuditExportRecord in
                    let regular = Self.exportView(record)
                    let view: JSONValue
                    do { view = try redactor?.redact(regular) ?? regular.view }
                    catch { throw AgentAuthorizationError.redactionFailed }
                    guard try AuditEncoding.encode(view).count <= 16 * 1024 else { throw AgentAuthorizationError.redactionFailed }
                    return .init(version: 1, storeID: regular.storeID, auditRecordID: regular.auditRecordID,
                        sequence: regular.sequence, committedDigest: regular.committedDigest, view: view)
                }
                let batchID = UUID()
                struct Content: Codable { let version: Int; let storeID: UUID; let destination: String; let configuration: String; let first: UInt64; let through: UInt64; let highWater: UInt64; let records: [AuditExportRecord] }
                let storeID = try await journal.requireAuditIdentity().storeID
                let bytes = try AuditEncoding.encode(Content(version: 1, storeID: storeID,
                    destination: configuration.destinationID, configuration: configurationDigest, first: acknowledged + 1,
                    through: page.scannedThroughSequence, highWater: highWater, records: records))
                let batch = AuditExportBatch(version: 1, exporterID: id, batchID: batchID, storeID: storeID,
                    destinationID: configuration.destinationID, configurationDigest: configurationDigest,
                    contentVersion: configuration.contentVersion, contentDigest: try await journal.auditDigest(bytes),
                    firstSequence: acknowledged + 1, throughSequence: page.scannedThroughSequence,
                    highWaterSequence: highWater, records: records)
                let ack = try await send(batch)
                guard !stopped else { throw AgentAuthorizationError.exporterStopped }
                try Task.checkCancellation()
                try await journal.commitAuditExport(configuration: configuration, exporterID: id, batch: batch, ack: ack,
                    expectedThrough: acknowledged)
                acknowledged = ack.throughSequence
            }
        } catch {
            if let error = error as? AgentAuthorizationError { failure = error }
            else if let error = error as? AgentJournalError { journalFailure = error; failure = .auditUnavailable }
            else if error is CancellationError { failure = .exporterStopped }
            else { failure = .auditUnavailable }
        }
        stopped = true
        // A timed-out/noncooperative sink still owns accepted network work and the Journal lease.
        await work.wait()
        await journal.releaseAuditExporter(configurationID: configuration.id, exporterID: id)
        drained = true; worker = nil
        await drain.complete()
    }

    private func send(_ batch: AuditExportBatch) async throws -> AuditExportAcknowledgement {
        for attempt in 1...configuration.maximumAttempts {
            try Task.checkCancellation()
            guard !stopped else { throw AgentAuthorizationError.exporterStopped }
            attempts += 1
            await work.begin()
            do {
                let sink = sink, work = work
                return try await withOperationDeadline(ContinuousClock.now.advanced(by: configuration.sinkTimeout),
                    timeoutError: AgentAuthorizationError.auditUnavailable) {
                    try await sink.write(batch)
                } onOperationFinished: { await work.end() }
            } catch {
                if error is CancellationError { throw error }
                if attempt == configuration.maximumAttempts { throw error }
                if configuration.retryDelay > .zero { try await Task.sleep(for: configuration.retryDelay) }
            }
        }
        throw AgentAuthorizationError.auditUnavailable
    }

    private static func exportView(_ record: AuditRecord) -> AuditExportRecord {
        var view: [String: JSONValue] = [
            "sessionID": .string(record.links.sessionID.uuidString), "runID": .string(record.links.runID.uuidString),
            "invocationID": .string(record.links.invocationID.uuidString), "proposalID": .string(record.links.proposalID.uuidString),
        ]
        if let id = record.links.authorizationID { view["authorizationID"] = .string(id.uuidString) }
        if let id = record.links.relatedProposalID { view["relatedProposalID"] = .string(id.uuidString) }
        switch record.fact {
        case .proposal(let p):
            view["kind"] = .string("proposal"); view["stage"] = .string(p.stage.rawValue)
            view["reconstructable"] = .bool(p.reconstructable)
            if let digest = p.actionDigest { view["actionDigest"] = .string(digest) }
        case .authorization(let a):
            view["kind"] = .string("authorization"); view["layer"] = .string(a.layer.rawValue)
            view["status"] = .string(a.status.rawValue)
            if let decision = a.decision {
                view["outcome"] = .string(decision.outcome.rawValue)
                view["subjectType"] = .string(decision.subject.type.rawValue)
            }
        case .disposition(let d): view["kind"] = .string("disposition"); view["state"] = .string(d.state.rawValue)
        case .result(let r):
            view["kind"] = .string("result"); view["referenceKind"] = .string(r.kind.rawValue)
            view["sourceRunID"] = .string(r.sourceRunID.uuidString)
            if let digest = r.outputDigest { view["outputDigest"] = .string(digest) }
        }
        return .init(version: 1, storeID: record.links.storeID, auditRecordID: record.auditRecordID,
            sequence: record.sequence, committedDigest: record.digest, view: .object(view))
    }
}

extension AgentJournal {
    package func requireAuditIdentity() throws -> JournalStoreIdentity {
        guard let identity = storeIdentity(), supportsAuthorizationAudit else { throw AgentAuthorizationError.auditStoreRequired }
        return identity
    }

    /// Explicit start is the only operation that sends data to a Host sink. No automatic networking.
    public func startAuditExporter(configuration: AuditExportConfiguration, sink: any AuditExportSink,
                                   redactor: (any AuditExportRedactor)? = nil) async throws -> AuditExporter {
        try Task.checkCancellation()
        guard !closing, let store, supportsAuthorizationAudit else { throw AgentAuthorizationError.auditStoreRequired }
        let digest = store.auditDigest(try configuration.digestBytes())
        guard auditExporterLeases[configuration.id] == nil else { throw AgentAuthorizationError.exporterInUse }
        let state = try store.read { view in
            let checkpoint = try view.auditExportCheckpoint(configuration.id)
            guard checkpoint.map({ $0.configurationDigest == digest }) ?? true else { throw AgentAuthorizationError.cursorMismatch }
            return (checkpoint?.throughSequence ?? 0, try view.auditHighWater())
        }
        let owner = UUID(); auditExporterLeases[configuration.id] = owner
        let exporter = AuditExporter(id: owner, journal: self, configuration: configuration, digest: digest,
            sink: sink, redactor: redactor, acknowledged: state.0, highWater: state.1)
        await exporter.start()
        return exporter
    }

    package func releaseAuditExporter(configurationID: String, exporterID: UUID) {
        if auditExporterLeases[configurationID] == exporterID { auditExporterLeases.removeValue(forKey: configurationID) }
    }

    package func commitAuditExport(configuration: AuditExportConfiguration, exporterID: UUID, batch: AuditExportBatch,
                                  ack: AuditExportAcknowledgement, expectedThrough: UInt64) throws {
        guard let store, auditExporterLeases[configuration.id] == exporterID else { throw AgentAuthorizationError.staleExporter }
        guard ack.version == 1, ack.exporterID == exporterID, ack.batchID == batch.batchID,
              ack.storeID == store.storeID, ack.destinationID == configuration.destinationID,
              ack.configurationDigest == batch.configurationDigest, ack.contentVersion == batch.contentVersion,
              ack.contentDigest == batch.contentDigest, ack.throughSequence >= batch.firstSequence,
              ack.throughSequence <= batch.throughSequence, batch.firstSequence == expectedThrough + 1 else {
            throw AgentAuthorizationError.invalidAcknowledgement
        }
        try writeStore(store) { view in
            let previous = try view.auditExportCheckpoint(configuration.id)
            if previous?.throughSequence == ack.throughSequence,
               previous?.batchID == batch.batchID, previous?.batchDigest == batch.contentDigest { return }
            try view.publishAuditExport(.init(checkpoint: .init(configurationID: configuration.id,
                configurationDigest: batch.configurationDigest, throughSequence: ack.throughSequence,
                batchID: batch.batchID, batchDigest: batch.contentDigest), expectedThroughSequence: expectedThrough))
        }
        scheduleMaintenanceIfNeeded()
    }
}
