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
    /// All `Codable` models define explicit `CodingKeys` enums for precise
    /// snake_case ↔ camelCase mapping. `.convertFromSnakeCase` acts as a
    /// fallback for any type that does not define its own `CodingKeys`.
    static let apiDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    /// Standard encoder used for all API request bodies.
    ///
    /// All `Encodable` models define explicit `CodingKeys` enums. `.convertToSnakeCase`
    /// acts as a fallback for any type that does not define its own `CodingKeys`.
    static let apiEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
