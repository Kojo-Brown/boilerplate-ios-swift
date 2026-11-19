import Core
import Foundation

// MARK: - The status-to-outcome mapping, in one place

/// Turns an HTTP status code and a response body into the outcome a caller of
/// `APIClient` sees.
///
/// Phase 12 item 5. This is an extraction and not a new rule: every line below
/// used to live inside `URLSessionAPIClient`, as a `private func validate` and
/// a `do`/`catch` around one `decode`. It moved out for one reason — the
/// *double* has to agree with it.
///
/// ## Why a shared mapping rather than a differential test alone
///
/// `MockAPIClient` substitutes the client, so everything the client decides is
/// exactly what it replaces. Before this item the double decided nothing: its
/// handler returned `Any` and the test author wrote the outcome directly, which
/// means a test could script an outcome the real transport cannot produce — a
/// decoded value for a 500, `unauthorized` where the live client throws
/// `httpError`, a `httpError` carrying a status in the 2xx range. Nothing
/// caught it, because the only description of the mapping was the live client's
/// own `switch`, and a double that reimplements a `switch` is a second copy to
/// get wrong.
///
/// So the double does not reimplement it. `MockAPIClient.script(_:)` is armed
/// with `(statusCode, body)` exchanges — the vocabulary the wire speaks — and
/// answers them by calling the functions here, which are the same functions
/// `URLSessionAPIClient` calls. Agreement between the two is then structural
/// rather than coincidental, and `DoubleContractTests` is what pins the parts
/// that cannot be shared that way: the decoder, the body, and the one path the
/// double deliberately does not model.
///
/// Having it here rather than beside `APIError` in `Core` is deliberate.
/// `APIError` is the error vocabulary and knows nothing about HTTP; "401 means
/// re-authenticate, 2xx means the body is the answer" is a transport policy,
/// and `Networking/Transport` is where the transport's policies live.
package enum APIResponseValidation {

    /// Whether `statusCode` is the one the transport answers by refreshing the
    /// access token and re-sending.
    ///
    /// Named rather than written as `== 401` at both of its call sites, because
    /// the two have to mean the same thing: `URLSessionAPIClient` asks this to
    /// decide whether to refresh, and `validate` asks it to decide which error
    /// to throw. A version of this that drifted — a transport that retried on
    /// 403 while the mapping still called 403 an `httpError` — would turn the
    /// retry into a silent second delivery that reported the wrong failure.
    package static func isUnauthorized(_ statusCode: Int) -> Bool {
        statusCode == 401
    }

    /// `data` when `statusCode` says the body is the answer, and otherwise the
    /// `APIError` that status maps to.
    ///
    /// `httpError` carries the body as well as the code because a 4xx body is
    /// usually the server's explanation, and a caller that only learns the
    /// number has to guess it.
    package static func validate(_ data: Data, statusCode: Int) throws -> Data {
        switch statusCode {
        case 200...299:
            return data
        case let code where isUnauthorized(code):
            throw APIError.unauthorized
        default:
            throw APIError.httpError(statusCode: statusCode, data: data)
        }
    }

    /// Decodes a validated body as `Response`, reporting a malformed one as
    /// `APIError.decodingFailed` rather than as a `DecodingError`.
    ///
    /// Only `DecodingError` is translated. Anything else a decoder throws is a
    /// programmer error here — a `JSONDecoder` whose strategy traps, a type
    /// whose `init(from:)` throws something of its own — and wrapping it in
    /// `decodingFailed` would dress it up as a bad response from the server.
    package static func decode<Response: Decodable & Sendable>(
        _ type: Response.Type,
        from data: Data,
        using decoder: JSONDecoder
    ) throws -> Response {
        do {
            return try decoder.decode(Response.self, from: data)
        } catch let error as DecodingError {
            throw APIError.decodingFailed(error.localizedDescription)
        }
    }
}
