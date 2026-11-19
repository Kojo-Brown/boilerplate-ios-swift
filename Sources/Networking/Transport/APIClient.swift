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

/// The protocol fake that stands in for `URLSessionAPIClient`.
///
/// `APIClient` is `Sendable`, so this double cannot hold a bare mutable stored
/// property. The state lives behind a lock rather than under
/// `@unchecked Sendable`: a test that swaps the handler from one task while
/// another is mid-`send` is then actually safe, instead of only asserted to be.
///
/// ## Two ways to arm it, and when each is the right one
///
/// **`handler`** answers in the vocabulary of *outcomes*: the closure is handed
/// the endpoint and returns the value, or throws the error, that `send` should
/// produce. It is the right choice when the test is about the caller — a view
/// model's loading states, a decorator's retry counting, a sync strategy's
/// choice — and the response is scenery.
///
/// **`script(_:)`** answers in the vocabulary of *the wire*: a list of
/// `(statusCode, body)` exchanges, mapped to outcomes by
/// `APIResponseValidation`, which is the same code `URLSessionAPIClient` calls.
/// It is the right choice when the test is about what the caller does with a
/// *server's* answer, because it cannot express an answer the real transport
/// would not produce. `handler` can: it will happily hand back a decoded value
/// for a status the live client turns into `httpError`, or throw `unauthorized`
/// where the live client throws `httpError`, and before Phase 12 item 5 nothing
/// in this package noticed. `DoubleContractTests` is what pins the agreement.
///
/// Arming it twice is arming it twice: `script(_:)` replaces any previous
/// script and takes precedence over `handler` until the script runs out.
package final class MockAPIClient: APIClient {
    package init() {}

    package typealias Handler = @Sendable (APIEndpoint) async throws -> Any

    /// One scripted answer, in the vocabulary the wire speaks.
    ///
    /// Deliberately the same shape as `StubURLProtocol.Exchange` in the test
    /// bundle, because the contract suite scripts both from one table and a
    /// difference in the shape would be a difference in what was tested.
    package struct Exchange: Sendable {
        package let statusCode: Int
        package let body: Data

        package init(statusCode: Int, body: Data = Data()) {
            self.statusCode = statusCode
            self.body = body
        }

        /// A 200 carrying `json`.
        package static func success(_ json: String) -> Exchange {
            Exchange(statusCode: 200, body: Data(json.utf8))
        }

        /// A 401 with an empty body — what an expired access token looks like.
        package static let unauthorized = Exchange(statusCode: 401)
    }

    /// Thrown when the code under test sent more requests than the test
    /// scripted.
    ///
    /// A test bug rather than a network condition, and it is spelled as its own
    /// type so that it cannot be mistaken for one: an `APIError` here would be
    /// classified, possibly retried, and reported as a server failure.
    package struct ScriptExhausted: Error, CustomStringConvertible {
        package let path: String

        package var description: String {
            "MockAPIClient had no scripted answer for \(path)"
        }
    }

    /// What one `send` resolved to under the lock.
    ///
    /// Three cases rather than an `Exchange?`, because "never armed with a
    /// script" and "armed, and the script ran out" are not the same answer and
    /// must not collapse into one: the first falls through to `handler`, the
    /// second is the test bug `ScriptExhausted` reports.
    private enum NextAnswer: Sendable {
        case useHandler
        case exchange(Exchange)
        case exhausted
    }

    private struct State: Sendable {
        var handler: Handler = { _ in EmptyResponse() }
        var isScripted = false
        var scripted: [Exchange] = []
        var recorded: [APIEndpoint] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package var handler: Handler {
        get { state.withLock { $0.handler } }
        set { state.withLock { $0.handler = newValue } }
    }

    /// Arms the double with the answers it will give, oldest first, and clears
    /// anything a previous script recorded.
    package func script(_ exchanges: [Exchange]) {
        state.withLock {
            $0.isScripted = true
            $0.scripted = exchanges
            $0.recorded = []
        }
    }

    /// Every endpoint this double was asked to send, in order, under either
    /// way of arming it.
    package var recordedEndpoints: [APIEndpoint] {
        state.withLock { $0.recorded }
    }

    package func send<Response: Decodable & Sendable>(_ endpoint: APIEndpoint) async throws -> Response {
        // Take the next exchange and record the call under one acquisition, so
        // two concurrent sends cannot both be handed the same answer.
        let next = state.withLock { current -> NextAnswer in
            current.recorded.append(endpoint)
            guard current.isScripted else { return .useHandler }
            guard !current.scripted.isEmpty else { return .exhausted }
            return .exchange(current.scripted.removeFirst())
        }

        switch next {
        case .exhausted:
            throw ScriptExhausted(path: endpoint.path)

        case let .exchange(exchange):
            // The same two calls, in the same order, that
            // `URLSessionAPIClient.send` makes — status first, then the body.
            let data = try APIResponseValidation.validate(
                exchange.body,
                statusCode: exchange.statusCode
            )
            return try APIResponseValidation.decode(Response.self, from: data, using: .apiDecoder)

        case .useHandler:
            break
        }

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
