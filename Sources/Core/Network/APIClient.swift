import Foundation

// MARK: - Protocol

/// Typed, generic HTTP client. Concrete types inject dependencies for testing.
protocol APIClient: Sendable {
    /// Sends `endpoint` and decodes the response body as `Response`.
    func send<Response: Decodable & Sendable>(_ endpoint: APIEndpoint) async throws -> Response
}

// MARK: - Convenience

extension APIClient {
    /// Sends `endpoint` and discards the response body (e.g. 204 No Content).
    @discardableResult
    func sendEmpty(_ endpoint: APIEndpoint) async throws -> EmptyResponse {
        try await send(endpoint)
    }
}

// MARK: - Mock

final class MockAPIClient: APIClient, @unchecked Sendable {
    typealias Handler = @Sendable (APIEndpoint) async throws -> Any

    var handler: Handler = { _ in EmptyResponse() }

    func send<Response: Decodable & Sendable>(_ endpoint: APIEndpoint) async throws -> Response {
        let result = try await handler(endpoint)
        guard let typed = result as? Response else {
            throw APIError.decodingFailed("MockAPIClient: expected \(Response.self)")
        }
        return typed
    }
}
