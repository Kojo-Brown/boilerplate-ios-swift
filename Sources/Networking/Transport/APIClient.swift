import Core
import Foundation
import os

// MARK: - Protocol

/// Typed, generic HTTP client. Concrete types inject dependencies for testing.
package protocol APIClient: Sendable {
    /// Sends `endpoint` and decodes the response body as `Response`.
    func send<Response: Decodable & Sendable>(_ endpoint: APIEndpoint) async throws -> Response
}

// MARK: - Convenience

extension APIClient {
    /// Sends `endpoint` and discards the response body (e.g. 204 No Content).
    @discardableResult
    package func sendEmpty(_ endpoint: APIEndpoint) async throws -> EmptyResponse {
        try await send(endpoint)
    }
}

// MARK: - Mock

/// `APIClient` is `Sendable`, so this double cannot hold a bare mutable stored
/// property. The handler lives behind a lock rather than under
/// `@unchecked Sendable`: a test that swaps the handler from one task while
/// another is mid-`send` is then actually safe, instead of only asserted to be.
package final class MockAPIClient: APIClient {
    package init() {}

    package typealias Handler = @Sendable (APIEndpoint) async throws -> Any

    private struct State: Sendable {
        var handler: Handler = { _ in EmptyResponse() }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package var handler: Handler {
        get { state.withLock { $0.handler } }
        set { state.withLock { $0.handler = newValue } }
    }

    package func send<Response: Decodable & Sendable>(_ endpoint: APIEndpoint) async throws -> Response {
        // Read the handler out of the lock *before* awaiting it. Holding an
        // unfair lock across a suspension point would let the awaiting task be
        // resumed on a different thread than the one that took it, which is
        // undefined behaviour for `os_unfair_lock`.
        let result = try await handler(endpoint)
        guard let typed = result as? Response else {
            throw APIError.decodingFailed("MockAPIClient: expected \(Response.self)")
        }
        return typed
    }
}
