import Foundation

/// Generic JSON envelope for APIs that wrap payloads in `{ "data": ..., "error": ..., "meta": ... }`.
struct APIResponse<T: Decodable & Sendable>: Decodable, Sendable {
    let data: T?
    let error: APIResponseError?
    let meta: ResponseMeta?

    enum CodingKeys: String, CodingKey {
        case data
        case error
        case meta
    }
}

// MARK: - Error body

struct APIResponseError: Decodable, Sendable, LocalizedError, Equatable {
    let code: String
    let message: String
    let details: [String: String]?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case details
    }

    var errorDescription: String? { message }
}

// MARK: - Response metadata

struct ResponseMeta: Decodable, Sendable, Equatable {
    let requestID: String?
    let version: String?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case version
    }
}
