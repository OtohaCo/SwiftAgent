import AgentCatalog
import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ProviderCatalogHTTPClient: Sendable {
    private let transport: any ProviderHTTPTransport
    private let maximumResponseBytes: Int

    init(transport: any ProviderHTTPTransport, maximumResponseBytes: Int = 2 * 1_024 * 1_024) {
        self.transport = transport
        self.maximumResponseBytes = maximumResponseBytes
    }

    func get(_ request: URLRequest) async throws -> Data {
        var receivedResponse = false
        var body = Data()
        do {
            for try await event in transport.stream(request) {
                try Task.checkCancellation()
                switch event {
                case .response(let status, let headers):
                    guard !receivedResponse else { throw ModelCatalogError(kind: .invalidResponse) }
                    guard status == 200 else { throw catalogError(status: status, headers: headers) }
                    receivedResponse = true
                case .data(let data):
                    guard receivedResponse else { throw ModelCatalogError(kind: .invalidResponse) }
                    guard data.count <= maximumResponseBytes - body.count else {
                        throw ModelCatalogError(kind: .responseTooLarge)
                    }
                    body.append(data)
                }
            }
            try Task.checkCancellation()
            guard receivedResponse else { throw ModelCatalogError(kind: .invalidResponse) }
            return body
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ModelCatalogError {
            throw error
        } catch let error as ModelProviderError {
            throw catalogError(error)
        } catch {
            throw ModelCatalogError(kind: .transport)
        }
    }

    private func catalogError(status: Int, headers: [String: String]) -> ModelCatalogError {
        catalogError(ProviderHTTPFailure.classify(status, headers: headers))
    }

    private func catalogError(_ error: ModelProviderError) -> ModelCatalogError {
        let kind: ModelCatalogError.Kind
        switch error.kind {
        case .authentication: kind = .authentication
        case .permissionDenied: kind = .permissionDenied
        case .rateLimited: kind = .rateLimited
        case .unavailable: kind = .unavailable
        case .transport: kind = .transport
        default: kind = .invalidResponse
        }
        return .init(kind: kind, retryAfter: error.retryAfter)
    }
}

func validateCatalogCredential(_ value: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !value.contains("\r"), !value.contains("\n") else {
        throw ModelCatalogError(kind: .invalidConfiguration)
    }
}

func validateCatalogEndpoint(_ endpoint: URL) throws {
    guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
        throw ModelCatalogError(kind: .invalidConfiguration)
    }
    let host = endpoint.host?.lowercased() ?? ""
    let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    guard !host.isEmpty,
          endpoint.user == nil,
          endpoint.password == nil,
          endpoint.fragment == nil,
          endpoint.scheme?.lowercased() == "https" || (endpoint.scheme?.lowercased() == "http" && loopback) else {
        throw ModelCatalogError(kind: .invalidConfiguration)
    }
    let sensitiveNames: Set<String> = [
        "api_key", "apikey", "authorization", "access_token", "token", "key", "x-api-key", "signature", "sig"
    ]
    guard components.queryItems?.allSatisfy({ item in
        let name = item.name.lowercased()
        let value = item.value ?? ""
        return !sensitiveNames.contains(name)
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }) ?? true else {
        throw ModelCatalogError(kind: .invalidConfiguration)
    }
}

func catalogEndpointScope(_ endpoint: URL) throws -> String {
    guard let endpointComponents = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
        throw ModelCatalogError(kind: .invalidConfiguration)
    }
    var components = URLComponents()
    components.scheme = endpoint.scheme?.lowercased()
    components.host = endpoint.host?.lowercased()
    components.port = endpoint.port
    components.percentEncodedPath = endpointComponents.percentEncodedPath
    components.percentEncodedQuery = endpointComponents.percentEncodedQuery
    guard let scope = components.url?.absoluteString else {
        throw ModelCatalogError(kind: .invalidConfiguration)
    }
    return scope
}

func catalogDetailURL(endpoint: URL, deploymentID: String) throws -> URL {
    guard deploymentID == deploymentID.trimmingCharacters(in: .whitespacesAndNewlines),
          !deploymentID.isEmpty,
          !deploymentID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
        throw ModelCatalogError(kind: .invalidConfiguration)
    }
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#")
    guard let encoded = deploymentID.addingPercentEncoding(withAllowedCharacters: allowed) else {
        throw ModelCatalogError(kind: .invalidConfiguration)
    }
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
        throw ModelCatalogError(kind: .invalidConfiguration)
    }
    let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    components.percentEncodedPath = basePath.isEmpty ? "/\(encoded)" : basePath.withLeadingSlash + "/\(encoded)"
    guard let url = components.url else { throw ModelCatalogError(kind: .invalidConfiguration) }
    return url
}

private extension String {
    var withLeadingSlash: String { hasPrefix("/") ? self : "/" + self }
}
