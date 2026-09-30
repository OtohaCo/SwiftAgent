import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation

// Compiled by the separate client package. Replace this controlled rule with Host policy.
struct ExampleEnterpriseAuthorizer: AgentAuthorizer {
    let allowedToolNames: Set<String>
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
        AuthorizationDecision(request: request,
            outcome: allowedToolNames.contains(request.toolDefinition.name) ? .allow : .deny,
            subject: .init(issuer: "example-host", subjectID: "local-rule", type: .automatedPolicy),
            policy: .init(id: "controlled-tools", version: "1", ruleReferences: ["exact-current-request"]),
            validFor: .seconds(30), reasonCode: "host_rule")
    }
}

func makeAuditedSession(directory: URL, operationDomain: String, model: ModelID,
                        provider: any ModelProvider, tools: [any AgentTool],
                        authorizer: any AgentAuthorizer,
                        identity: AgentAuthorizationIdentity) throws -> (AgentSession, AgentJournal) {
    let journal = try AgentIncrementalJournal.create(at: directory,
        operationDomain: operationDomain, supportsAuthorizationAudit: true)
    let agent = try Agent(model: model, provider: provider, tools: tools,
        configuration: .init(authorization: .init(mode: .requiredAudit,
            authorizer: authorizer, identity: identity)))
    return (try agent.makeSession(journal: journal), journal)
}

// Host destination adapter: the closure authenticates and durably deduplicates by
// (storeID, auditRecordID) before returning. No default destination or credentials.
struct ExampleEnterpriseSink: AuditExportSink {
    let acceptDurably: @Sendable (AuditExportBatch) async throws -> Void
    func write(_ batch: AuditExportBatch) async throws -> AuditExportAcknowledgement {
        try await acceptDurably(batch)
        return .init(batch: batch)
    }
}

func exportOnePass(journal: AgentJournal, sink: any AuditExportSink) async throws -> AuditExportStatus {
    let exporter = try await journal.startAuditExporter(configuration: .init(
        id: "enterprise-archive-v1", destinationID: "host-receiver",
        contentVersion: "1", redactionVersion: "conservative-v1"), sink: sink)
    try await exporter.waitForDrain()
    return await exporter.status()
}
