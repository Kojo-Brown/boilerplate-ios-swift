import Foundation

// MARK: - HTTP Method

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

// MARK: - Endpoint

/// A fully-specified description of one HTTP request, body already encoded.
struct APIEndpoint: Sendable {
    let method: HTTPMethod
    let path: String
    let queryItems: [URLQueryItem]
    let body: Data?
    let requiresAuth: Bool

    init(
        method: HTTPMethod,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        requiresAuth: Bool = true
    ) {
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.body = body
        self.requiresAuth = requiresAuth
    }

    // MARK: - Factory helpers

    static func get(
        _ path: String,
        queryItems: [URLQueryItem] = [],
        requiresAuth: Bool = true
    ) -> APIEndpoint {
        APIEndpoint(method: .get, path: path, queryItems: queryItems, requiresAuth: requiresAuth)
    }

    static func post<Body: Encodable & Sendable>(
        _ path: String,
        body: Body,
        encoder: JSONEncoder = .apiEncoder,
        requiresAuth: Bool = true
    ) throws -> APIEndpoint {
        APIEndpoint(
            method: .post,
            path: path,
            body: try encoder.encode(body),
            requiresAuth: requiresAuth
        )
    }

    static func put<Body: Encodable & Sendable>(
        _ path: String,
        body: Body,
        encoder: JSONEncoder = .apiEncoder,
        requiresAuth: Bool = true
    ) throws -> APIEndpoint {
        APIEndpoint(
            method: .put,
            path: path,
            body: try encoder.encode(body),
            requiresAuth: requiresAuth
        )
    }

    static func patch<Body: Encodable & Sendable>(
        _ path: String,
        body: Body,
        encoder: JSONEncoder = .apiEncoder,
        requiresAuth: Bool = true
    ) throws -> APIEndpoint {
        APIEndpoint(
            method: .patch,
            path: path,
            body: try encoder.encode(body),
            requiresAuth: requiresAuth
        )
    }

    static func delete(
        _ path: String,
        requiresAuth: Bool = true
    ) -> APIEndpoint {
        APIEndpoint(method: .delete, path: path, requiresAuth: requiresAuth)
    }
}

// MARK: - Empty response sentinel

/// Used for endpoints that return 204 No Content or an empty body.
struct EmptyResponse: Decodable, Sendable {}

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
    static let apiDecoder: JSONDecoder = {
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
    static let apiEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
