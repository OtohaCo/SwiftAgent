import AgentCatalog
import AgentModels
import Foundation
import Testing

struct ModelCatalogCacheTests {
    @Test func hostManifestRevisionIsPublishedAsTheSnapshotRevision() async throws {
        let scope = try fixtureScope(service: "manifest")
        let provider = StaticModelCatalogProvider(manifest: try .init(
            scope: scope,
            revision: "manifest-42",
            models: [fixtureEntry("alpha", scope: scope)]
        ))

        let snapshot = try await ModelCatalogCache().refresh(using: provider)

        #expect(snapshot.revision == "manifest-42")
    }

    @Test func paginatedRefreshDeduplicatesAndPublishesAtomically() async throws {
        let scope = try fixtureScope(service: "west")
        let provider = FixtureCatalogProvider(scope: scope, pages: [
            nil: .success(.init(models: [fixtureEntry("alpha", scope: scope)], nextCursor: "page-2")),
            "page-2": .success(.init(models: [
                fixtureEntry("alpha", scope: scope), fixtureEntry("beta", scope: scope),
            ])),
        ])
        let clock = CatalogClock(now: Date(timeIntervalSince1970: 100))
        let cache = ModelCatalogCache(now: { clock.value })

        let snapshot = try await cache.refresh(
            using: provider,
            policy: .init(timeToLive: 60, pageSize: 2, maximumPages: 4)
        )

        #expect(snapshot.state == .fresh)
        #expect(snapshot.models.map(\.model.name) == ["alpha", "beta"])
        #expect(snapshot.fetchedAt == Date(timeIntervalSince1970: 100))
        #expect(snapshot.expiresAt == Date(timeIntervalSince1970: 160))
        #expect(await provider.requestedCursors == [nil, "page-2"])
    }

    @Test func failedRefreshRetainsLastKnownGoodAsStale() async throws {
        let scope = try fixtureScope(service: "west")
        let provider = FixtureCatalogProvider(scope: scope, pages: [
            nil: .success(.init(models: [fixtureEntry("alpha", scope: scope)])),
        ])
        let clock = CatalogClock(now: Date(timeIntervalSince1970: 100))
        let cache = ModelCatalogCache(now: { clock.value })
        _ = try await cache.refresh(using: provider, policy: .init(timeToLive: 60))
        await provider.replace(pages: [nil: .failure(FixtureCatalogError.offline)])

        await #expect(throws: FixtureCatalogError.offline) {
            try await cache.refresh(using: provider, policy: .init(timeToLive: 60))
        }
        let retained = try #require(await cache.snapshot(for: scope))
        #expect(retained.state == .stale)
        #expect(retained.models.map(\.model.name) == ["alpha"])
        #expect(retained.lastRefreshFailureAt == Date(timeIntervalSince1970: 100))
    }

    @Test func repeatedCursorFailsWithoutReplacingThePriorSnapshot() async throws {
        let scope = try fixtureScope(service: "west")
        let good = FixtureCatalogProvider(scope: scope, pages: [
            nil: .success(.init(models: [fixtureEntry("alpha", scope: scope)])),
        ])
        let cache = ModelCatalogCache(now: { Date(timeIntervalSince1970: 100) })
        _ = try await cache.refresh(using: good)
        let looping = FixtureCatalogProvider(scope: scope, pages: [
            nil: .success(.init(models: [fixtureEntry("changed", scope: scope)], nextCursor: "again")),
            "again": .success(.init(models: [], nextCursor: "again")),
        ])

        await #expect(throws: ModelCatalogError.self) { try await cache.refresh(using: looping) }
        #expect(await cache.snapshot(for: scope)?.models.map(\.model.name) == ["alpha"])
    }

    @Test func cacheKeysIncludeServiceAndAuthorizationScope() async throws {
        let west = try fixtureScope(service: "west", authorization: "project-a")
        let east = try fixtureScope(service: "east", authorization: "project-b")
        let cache = ModelCatalogCache()
        _ = try await cache.refresh(using: FixtureCatalogProvider(scope: west, pages: [
            nil: .success(.init(models: [fixtureEntry("west-model", scope: west)])),
        ]))
        _ = try await cache.refresh(using: FixtureCatalogProvider(scope: east, pages: [
            nil: .success(.init(models: [fixtureEntry("east-model", scope: east)])),
        ]))

        #expect(await cache.snapshot(for: west)?.models.map(\.model.name) == ["west-model"])
        #expect(await cache.snapshot(for: east)?.models.map(\.model.name) == ["east-model"])
    }

    @Test func olderInitialRefreshCannotOverwriteANewerSnapshot() async throws {
        let scope = try fixtureScope(service: "west")
        let provider = OverlappingCatalogProvider(scope: scope)
        let cache = ModelCatalogCache(now: { Date(timeIntervalSince1970: 100) })

        let older = Task { try await cache.refresh(using: provider) }
        await provider.waitUntilOlderRefreshIsBlocked()
        let newer = try await cache.refresh(using: provider)
        await provider.releaseOlderRefresh()

        await #expect(throws: ModelCatalogError(kind: .supersededRefresh)) {
            try await older.value
        }
        #expect(newer.models.map(\.model.name) == ["newer"])
        let published = try #require(await cache.snapshot(for: scope))
        #expect(published.state == .fresh)
        #expect(published.models.map(\.model.name) == ["newer"])
        #expect(published.lastRefreshFailureAt == nil)
    }
}

private final class CatalogClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date

    init(now: Date) { self.now = now }

    var value: Date { lock.withLock { now } }
}

private actor FixtureCatalogProvider: ModelCatalogProvider {
    nonisolated let scope: ModelServiceScope
    private var pages: [String?: Result<ModelCatalogPage, Error>]
    private(set) var requestedCursors: [String?] = []

    init(scope: ModelServiceScope, pages: [String?: Result<ModelCatalogPage, Error>]) {
        self.scope = scope
        self.pages = pages
    }

    func listModels(_ request: ModelCatalogRequest) async throws -> ModelCatalogPage {
        requestedCursors.append(request.cursor)
        guard let result = pages[request.cursor] else { throw FixtureCatalogError.missingPage }
        return try result.get()
    }

    func replace(pages: [String?: Result<ModelCatalogPage, Error>]) {
        self.pages = pages
    }
}

private actor OverlappingCatalogProvider: ModelCatalogProvider {
    nonisolated let scope: ModelServiceScope
    private var invocationCount = 0
    private var olderContinuation: CheckedContinuation<Void, Never>?
    private var blockedObservers: [CheckedContinuation<Void, Never>] = []

    init(scope: ModelServiceScope) {
        self.scope = scope
    }

    func listModels(_ request: ModelCatalogRequest) async throws -> ModelCatalogPage {
        invocationCount += 1
        if invocationCount == 1 {
            await withCheckedContinuation { continuation in
                olderContinuation = continuation
                let observers = blockedObservers
                blockedObservers.removeAll()
                observers.forEach { $0.resume() }
            }
            return .init(models: [fixtureEntry("older", scope: scope)])
        }
        return .init(models: [fixtureEntry("newer", scope: scope)])
    }

    func waitUntilOlderRefreshIsBlocked() async {
        if olderContinuation != nil { return }
        await withCheckedContinuation { blockedObservers.append($0) }
    }

    func releaseOlderRefresh() {
        olderContinuation?.resume()
        olderContinuation = nil
    }
}

private enum FixtureCatalogError: Error, Equatable { case offline, missingPage }

private func fixtureScope(service: String, authorization: String = "project") throws -> ModelServiceScope {
    try .init(
        provider: "fixture",
        serviceInstanceID: service,
        endpointScope: "https://\(service).example.test/v1",
        apiDialect: "fixture",
        authorizationScopeID: authorization
    )
}

private func fixtureEntry(_ name: String, scope: ModelServiceScope) -> ModelCatalogEntry {
    .init(
        model: .init(provider: scope.provider, name: name),
        deploymentID: name,
        serviceScope: scope,
        sources: [.init(kind: .upstreamAPI)]
    )
}
