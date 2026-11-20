import Foundation
import os
@testable import Core
@testable import Networking

// MARK: - A server rather than a client

/// A stateful, in-process `/users/me` that answers real status codes with real
/// JSON, behind a real `URLSession`.
///
/// This is the double the network seam actually wants, and it is deliberately
/// not another `APIClient`. `MockAPIClient` substitutes the client, so
/// everything `URLSessionAPIClient` does — building the `URLRequest`, attaching
/// the bearer token and the idempotency key, mapping a status code to an
/// `APIError`, decoding the body — is exactly what it replaces. A test using it
/// is a test of `LiveUserRepository`'s two lines and of nothing underneath
/// them, and it cannot produce any failure the real stack produces, because the
/// handler hands back a value that is already decoded.
///
/// Replacing the *server* leaves all of that in the test's path and removes
/// only the wire. That is what makes a contract shared with
/// `MockUserRepository` meaningful: the hand-written double is held against the
/// behaviour of the whole real stack rather than against a reading of the
/// protocol's doc comment.
///
/// `StubURLProtocol` is the same idea one step less far along — it scripts a
/// queue of answers, which is right for asserting what went onto the wire and
/// wrong for a contract, because a contract case has to be able to *read back*
/// what a previous case in the same scenario wrote. So this one holds a record
/// instead of a queue: a `PATCH` changes it and the next `GET` sees the change,
/// which is the only way "an edit is visible to the next fetch" can be one
/// sentence asserted against both implementations.
///
/// ## Why the state is static, and why that costs a `.serialized` suite
///
/// `URLSession` instantiates the protocol class itself, per request, so there is
/// no instance for a test to hold and configure. The record has to be reachable
/// from a type constructed out of reach, which makes it a shared mutable
/// global — so the suites that use it are `.serialized`, and it gets its own
/// class and its own session rather than sharing `StubURLProtocol`'s, for the
/// reason `AttestationStubURLProtocol` documents: `.serialized` orders the tests
/// *within* one suite, and Swift Testing runs suites in parallel with each
/// other.
///
/// The lock is `OSAllocatedUnfairLock` rather than `nonisolated(unsafe)`, like
/// every other piece of shared state in this package: `startLoading()` runs on
/// a `URLSession` delegate thread.
///
/// Not `final`, unlike every other double here. `URLProtocol`'s entry points are
/// `class func`s that a subclass overrides, and `static_over_final_class` reads
/// a `class func` in a `final class` as one that should have been `static` —
/// which these cannot be, because they override.
class FakeUserAPI: URLProtocol {

    // MARK: - Configuration

    /// What `DELETE /users/me` answers with.
    ///
    /// Two answers, both of them things a real server does, because the
    /// difference between them is not cosmetic here: see
    /// `UserRepositoryDoubleDivergences.aNoContentDeleteFailsOnlyAgainstTheLiveStack`.
    enum DeleteAnswer: Sendable {
        /// `200` carrying `{}` — a body `EmptyResponse` can decode.
        case okEmptyObject

        /// `204 No Content` with an empty body, which is the correct answer to a
        /// `DELETE` and is not valid JSON.
        case noContent
    }

    /// One request this server was asked to serve.
    struct Call: Sendable {
        let method: String
        let path: String
        let idempotencyKey: String?
        let authorization: String?
        let body: Data
    }

    private struct State: Sendable {
        var user: User?
        var deleteAnswer: DeleteAnswer = .okEmptyObject
        var calls: [Call] = []

        /// The response body already returned for an `Idempotency-Key`, so that
        /// a second delivery of one edit is answered rather than applied twice.
        var accepted: [String: Data] = [:]
    }

    private static let state = OSAllocatedUnfairLock(initialState: State(user: nil))

    /// Seeds the record and forgets everything a previous test did.
    static func reset(user: User?, deleteAnswer: DeleteAnswer = .okEmptyObject) {
        state.withLock { $0 = State(user: user, deleteAnswer: deleteAnswer) }
    }

    /// The profile the server currently holds, or `nil` once it has been deleted.
    static var storedUser: User? {
        state.withLock { $0.user }
    }

    /// Every request the server was handed, in order.
    static var calls: [Call] {
        state.withLock { $0.calls }
    }

    /// The base URL a client has to be built with to reach this server.
    ///
    /// `.invalid` is reserved by RFC 6761 and can never resolve, so a request
    /// that escapes the `URLProtocol` fails rather than leaving the machine.
    static let baseURL = URL(string: "https://fake-user-api.invalid/v1")!

    /// The session that routes everything through this server.
    ///
    /// Ephemeral, so nothing is written to a URL cache between tests, and
    /// installed on the configuration rather than through
    /// `URLProtocol.registerClass` so it cannot affect a session some other
    /// suite built. One session for the whole suite, for the reason
    /// `StubURLProtocol.session` gives: a `URLSession` retains itself until it
    /// is invalidated and a `@Suite` struct has no teardown hook to invalidate
    /// one in.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeUserAPI.self]
        return URLSession(configuration: configuration)
    }()

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let call = Call(
            method: request.httpMethod ?? "GET",
            path: request.url?.path ?? "",
            idempotencyKey: request.value(forHTTPHeaderField: IdempotencyKey.headerField),
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            body: FakeUserAPI.body(of: request)
        )

        let answer = FakeUserAPI.state.withLock { current -> Answer in
            current.calls.append(call)
            return FakeUserAPI.route(call, against: &current)
        }

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: answer.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    // MARK: - The server

    private struct Answer: Sendable {
        let statusCode: Int
        let body: Data

        static func json(_ text: String, status: Int = 200) -> Answer {
            Answer(statusCode: status, body: Data(text.utf8))
        }

        static let notFound = Answer.json(#"{"error":{"code":"not_found","message":"No such user"}}"#, status: 404)
        static let badRequest = Answer.json(#"{"error":{"code":"bad_request","message":"Unreadable"}}"#, status: 400)
        static let unauthorized = Answer.json(#"{"error":{"code":"unauthorized","message":"No token"}}"#, status: 401)
    }

    /// The whole of the routing, and the only place the record is changed.
    ///
    /// `inout` rather than a second `withLock`: reading the record, deciding,
    /// and writing it back have to be one critical section, or two concurrent
    /// deliveries of one edit both miss the ledger and both apply.
    private static func route(_ call: Call, against state: inout State) -> Answer {
        guard call.path.hasSuffix("/users/me") else { return .notFound }

        // Every route here is authenticated, so the token is checked rather than
        // merely recorded. The client sets the header for any endpoint declaring
        // `requiresAuth`, so this never fires in a passing run — which is the
        // point: a transport that stopped attaching it would arrive here as a
        // 401 and a refresh attempt, not as a green contract.
        let credential = call.authorization ?? ""
        guard credential.hasPrefix("Bearer ") else { return .unauthorized }

        switch call.method {
        case "GET":
            guard let user = state.user else { return .notFound }
            return encoded(user)

        case "PATCH":
            return patch(call, against: &state)

        case "DELETE":
            guard state.user != nil else { return .notFound }
            state.user = nil
            switch state.deleteAnswer {
            case .okEmptyObject: return .json("{}")
            case .noContent: return Answer(statusCode: 204, body: Data())
            }

        default:
            return .notFound
        }
    }

    private static func patch(_ call: Call, against state: inout State) -> Answer {
        guard let user = state.user else { return .notFound }

        // A redelivery of an edit the server already accepted is answered with
        // the response it gave the first time, and is *not* applied again. That
        // is what an `Idempotency-Key` is for, and a fake that ignored it would
        // let `RetryingUserRepository` look correct while double-writing.
        if let key = call.idempotencyKey, let previous = state.accepted[key] {
            return Answer(statusCode: 200, body: previous)
        }

        guard let name = try? JSONDecoder.apiDecoder.decode(NameEdit.self, from: call.body).name else {
            return .badRequest
        }

        let updated = user.with(name: .set(name), version: .set((user.version ?? 0) + 1))
        state.user = updated
        let response = encoded(updated)
        if let key = call.idempotencyKey {
            state.accepted[key] = response.body
        }
        return response
    }

    /// The server's own view of the `PATCH` body, decoded rather than assumed.
    ///
    /// `UpdateProfileRequest` is `Encodable` only, and a server that shared the
    /// client's type would not be checking that the client encodes what the
    /// server reads.
    private struct NameEdit: Decodable {
        let name: String

        enum CodingKeys: String, CodingKey {
            case name
        }
    }

    private static func encoded(_ user: User) -> Answer {
        guard let body = try? JSONEncoder.apiEncoder.encode(user) else {
            return Answer(statusCode: 500, body: Data())
        }
        return Answer(statusCode: 200, body: body)
    }

    // MARK: - Reading the request body

    /// `URLRequest.httpBody` is `nil` inside a `URLProtocol` for a body
    /// `URLSession` chose to stream, which it does for the `PATCH` this server
    /// exists to serve. Reading only `httpBody` is the mistake that makes a
    /// fake server answer every edit with "unreadable" and look like a server
    /// bug.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }

        stream.open()
        defer { stream.close() }

        let capacity = 4_096
        var buffer = [UInt8](repeating: 0, count: capacity)
        var data = Data()
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: capacity)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }
}
