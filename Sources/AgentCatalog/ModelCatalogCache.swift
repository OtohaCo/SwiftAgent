import Foundation

public struct ModelCatalogRefreshPolicy: Hashable, Sendable, Codable {
    public let timeToLive: TimeInterval
    public let pageSize: Int?
    public let maximumPages: Int

    public init(timeToLive: TimeInterval = 300, pageSize: Int? = nil, maximumPages: Int = 20) {
        self.timeToLive = timeToLive
        self.pageSize = pageSize
        self.maximumPages = maximumPages
    }
}

public struct ModelCatalogSnapshotState: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let fresh = Self(rawValue: "fresh")
    public static let stale = Self(rawValue: "stale")

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ModelCatalogSnapshot: Hashable, Sendable, Codable {
    public let scope: ModelServiceScope
    public let revision: String
    public let models: [ModelCatalogEntry]
    public let fetchedAt: Date
    public let expiresAt: Date
    public let state: ModelCatalogSnapshotState
    public let lastRefreshFailureAt: Date?

    init(
        scope: ModelServiceScope,
        revision: String,
        models: [ModelCatalogEntry],
        fetchedAt: Date,
        expiresAt: Date,
        state: ModelCatalogSnapshotState,
        lastRefreshFailureAt: Date?
    ) {
        self.scope = scope
        self.revision = revision
        self.models = models
        self.fetchedAt = fetchedAt
        self.expiresAt = expiresAt
        self.state = state
        self.lastRefreshFailureAt = lastRefreshFailureAt
    }
}

/// Bounded, Host-driven metadata cache. It never starts a background refresh.
public actor ModelCatalogCache {
    private struct Stored: Sendable {
        var snapshot: ModelCatalogSnapshot
        var refreshGeneration: UUID?
    }

    private let now: @Sendable () -> Date
    private var stored: [ModelServiceScope: Stored] = [:]
    private var refreshGenerations: [ModelServiceScope: UUID] = [:]

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func refresh(
        using provider: any ModelCatalogProvider,
        policy: ModelCatalogRefreshPolicy = .init()
    ) async throws -> ModelCatalogSnapshot {
        guard policy.timeToLive >= 0,
              policy.maximumPages > 0,
              policy.pageSize.map({ $0 > 0 }) ?? true else {
            throw ModelCatalogError(kind: .invalidConfiguration)
        }
        let scope = provider.scope
        let generation = UUID()
        refreshGenerations[scope] = generation
        if var current = stored[scope] {
            current.refreshGeneration = generation
            stored[scope] = current
        }

        do {
            var cursor: String?
            var seenCursors = Set<String>()
            var entries: [String: ModelCatalogEntry] = [:]
            var pageCount = 0
            repeat {
                try Task.checkCancellation()
                guard pageCount < policy.maximumPages else {
                    throw ModelCatalogError(kind: .pageLimitReached)
                }
                pageCount += 1
                let page = try await provider.listModels(.init(cursor: cursor, pageSize: policy.pageSize))
                guard !page.isPartial else { throw ModelCatalogError(kind: .incompleteRefresh) }
                for entry in page.models {
                    guard entry.serviceScope == scope,
                          entry.model.provider == scope.provider else {
                        throw ModelCatalogError(kind: .scopeMismatch)
                    }
                    if let existing = entries[entry.deploymentID], existing != entry {
                        throw ModelCatalogError(kind: .conflictingDuplicate)
                    }
                    entries[entry.deploymentID] = entry
                }
                cursor = page.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted {
                    throw ModelCatalogError(kind: .repeatedCursor)
                }
            } while cursor != nil

            let fetchedAt = now()
            let snapshot = ModelCatalogSnapshot(
                scope: scope,
                revision: provider.catalogRevision ?? UUID().uuidString,
                models: entries.values.sorted {
                    if $0.model.name == $1.model.name { return $0.deploymentID < $1.deploymentID }
                    return $0.model.name < $1.model.name
                },
                fetchedAt: fetchedAt,
                expiresAt: fetchedAt.addingTimeInterval(policy.timeToLive),
                state: .fresh,
                lastRefreshFailureAt: nil
            )
            guard refreshGenerations[scope] == generation else {
                throw ModelCatalogError(kind: .supersededRefresh)
            }
            stored[scope] = .init(snapshot: snapshot, refreshGeneration: nil)
            refreshGenerations.removeValue(forKey: scope)
            return snapshot
        } catch {
            if refreshGenerations[scope] == generation, var current = stored[scope] {
                current.snapshot = stale(current.snapshot, failureAt: now())
                if current.refreshGeneration == generation { current.refreshGeneration = nil }
                stored[scope] = current
            }
            if refreshGenerations[scope] == generation {
                refreshGenerations.removeValue(forKey: scope)
            }
            throw error
        }
    }

    public func snapshot(for scope: ModelServiceScope) -> ModelCatalogSnapshot? {
        guard let current = stored[scope]?.snapshot else { return nil }
        if current.lastRefreshFailureAt != nil || now() >= current.expiresAt {
            return stale(current, failureAt: current.lastRefreshFailureAt)
        }
        return current
    }

    public func removeSnapshot(for scope: ModelServiceScope) {
        stored.removeValue(forKey: scope)
        refreshGenerations.removeValue(forKey: scope)
    }

    public func removeAll() {
        stored.removeAll()
        refreshGenerations.removeAll()
    }

    private func stale(_ snapshot: ModelCatalogSnapshot, failureAt: Date?) -> ModelCatalogSnapshot {
        .init(
            scope: snapshot.scope,
            revision: snapshot.revision,
            models: snapshot.models,
            fetchedAt: snapshot.fetchedAt,
            expiresAt: snapshot.expiresAt,
            state: .stale,
            lastRefreshFailureAt: failureAt
        )
    }
}
