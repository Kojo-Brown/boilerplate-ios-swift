import Foundation

/// Generic JSON envelope for APIs that wrap payloads in `{ "data": ..., "error": ..., "meta": ... }`.
package struct APIResponse<T: Decodable & Sendable>: Decodable, Sendable {
    package let data: T?
    package let error: APIResponseError?
    package let meta: ResponseMeta?

    package enum CodingKeys: String, CodingKey {
        case data
        case error
        case meta
    }
}

// MARK: - Error body

package struct APIResponseError: Decodable, Sendable, LocalizedError, Equatable {
    package let code: String
    package let message: String
    package let details: [String: String]?

    package enum CodingKeys: String, CodingKey {
        case code
        case message
        case details
    }

    package var errorDescription: String? { message }
}

// MARK: - Response metadata

package struct ResponseMeta: Decodable, Sendable, Equatable {
    package let requestID: String?
    package let version: String?

    package enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case version
    }
}
