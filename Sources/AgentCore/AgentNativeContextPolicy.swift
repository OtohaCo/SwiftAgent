import AgentModels

/// Frozen Run policy. It requests one native compact before the first generation
/// inside an already admitted Run. It neither summarizes locally nor retries tools.
public struct AgentNativeContextPolicy: Hashable, Sendable, Codable {
    public let compactBeforeGeneration: ModelCompactionMode?
    public let maximumMaintenanceRounds: Int
    public init(compactBeforeGeneration: ModelCompactionMode? = nil, maximumMaintenanceRounds: Int = 4) throws {
        guard maximumMaintenanceRounds > 0,
              compactBeforeGeneration == nil || compactBeforeGeneration == .anthropicOnDemand || compactBeforeGeneration == .openAIStandalone else {
            throw ModelProviderError(kind: .invalidRequest, message: "Invalid controlled native compaction policy.")
        }
        self.compactBeforeGeneration = compactBeforeGeneration; self.maximumMaintenanceRounds = maximumMaintenanceRounds
    }
    private enum CodingKeys: String, CodingKey { case compactBeforeGeneration, maximumMaintenanceRounds }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(compactBeforeGeneration: c.decodeIfPresent(ModelCompactionMode.self, forKey: .compactBeforeGeneration),
                      maximumMaintenanceRounds: c.decode(Int.self, forKey: .maximumMaintenanceRounds))
    }
}
