import Foundation

// MARK: - HTTP Method

package enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

// MARK: - Endpoint

/// A fully-specified description of one HTTP request, body already encoded.
package struct APIEndpoint: Sendable {
    package let method: HTTPMethod
    package let path: String
    package let queryItems: [URLQueryItem]
    package let body: Data?
    package let requiresAuth: Bool

    /// The key identifying the logical request this endpoint is one delivery
    /// of, sent as `Idempotency-Key`. `nil` for a request that needs none.
    ///
    /// It lives on the endpoint rather than being a parameter of `send` because
    /// an endpoint is "one HTTP request, fully specified", and whether a repeat
    /// of that request is safe is part of specifying it. Threading it beside
    /// the endpoint instead would let the two be separated — an endpoint value
    /// stored, passed on, and eventually sent without the key that made it
    /// replayable.
    package let idempotencyKey: IdempotencyKey?

    /// - Parameter idempotencyKey: Must be `nil` for a `GET`. A safe method has
    ///   nothing to de-duplicate, and a key on one is at best noise in the
    ///   server's log and at worst a cache-key mismatch in a proxy that varies
    ///   on request headers. The factory helpers make this unreachable — `get`
    ///   does not accept a key — so reaching it means constructing the endpoint
    ///   by hand and is a programmer error.
    package init(
        method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        requiresAuth: Bool = true,
        idempotencyKey: IdempotencyKey? = nil
    ) {
        precondition(
            idempotencyKey == nil || method != .get,
            "A GET is safe and has no duplicate to collapse; \(path) was given an idempotency key"
        )
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.body = body
        self.requiresAuth = requiresAuth
        self.idempotencyKey = idempotencyKey
    }

    // MARK: - Factory helpers

    package static func get(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        requiresAuth: Bool = true
    ) -> APIEndpoint {
        APIEndpoint(method: .get, path: path, queryItems: queryItems, requiresAuth: requiresAuth)
    }

    package static func post<Body: Encodable & Sendable>(
        _ path: String,
        body: Body,
        encoder: JSONEncoder = .apiEncoder,
        requiresAuth: Bool = true,
        idempotencyKey: IdempotencyKey? = nil
    ) throws -> APIEndpoint {
        APIEndpoint(
            method: .post,
            path: path,
            body: try encoder.encode(body),
            requiresAuth: requiresAuth,
            idempotencyKey: idempotencyKey
        )
    }

    package static func put<Body: Encodable & Sendable>(
        _ path: String,
        body: Body,
        encoder: JSONEncoder = .apiEncoder,
        requiresAuth: Bool = true,
        idempotencyKey: IdempotencyKey? = nil
    ) throws -> APIEndpoint {
        APIEndpoint(
            method: .put,
            path: path,
            body: try encoder.encode(body),
            requiresAuth: requiresAuth,
            idempotencyKey: idempotencyKey
        )
    }

    package static func patch<Body: Encodable & Sendable>(
        _ path: String,
        body: Body,
        encoder: JSONEncoder = .apiEncoder,
        requiresAuth: Bool = true,
        idempotencyKey: IdempotencyKey? = nil
    ) throws -> APIEndpoint {
        APIEndpoint(
            method: .patch,
            path: path,
            body: try encoder.encode(body),
            requiresAuth: requiresAuth,
            idempotencyKey: idempotencyKey
        )
    }

    package static func delete(
        _ path: String,
        requiresAuth: Bool = true,
        idempotencyKey: IdempotencyKey? = nil
    ) -> APIEndpoint {
        APIEndpoint(
            method: .delete,
            path: path,
            requiresAuth: requiresAuth,
            idempotencyKey: idempotencyKey
        )
    }
}

// MARK: - Empty response sentinel

/// Used for endpoints that return 204 No Content or an empty body.
package struct EmptyResponse: Decodable, Sendable {}

// MARK: - JSONDecoder / JSONEncoder defaults

extension JSONDecoder {
    /// Standard decoder used by all API responses.
    ///
    /// Deliberately does **not** set `keyDecodingStrategy`. Every `Codable` model in
    /// this package declares an explicit `CodingKeys` enum, and a key strategy is not
    /// the fallback it looks like: `.convertFromSnakeCase` rewrites the *incoming JSON
    /// key* before it is matched against `CodingKeys`, so `"avatar_url"` arrived as
    /// `avatarUrl` and matched no key at all. Optional properties then decoded as nil
    /// (`User.avatarURL`, `ResponseMeta.requestID`) and non-optional ones threw
    /// `keyNotFound` (`TokenPair.accessToken`) — the two combined cancel out.
    package static let apiDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    /// Standard encoder used for all API request bodies.
    ///
    /// Symmetrically to `apiDecoder`, no `keyEncodingStrategy`: the explicit
    /// `CodingKeys` already emit snake_case, and layering a strategy on top would
    /// re-transform keys that are already in their wire form.
    package static let apiEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
