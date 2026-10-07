import Core
import Foundation

/// Posts crash reports to the API, and classifies what comes back.
///
/// ## Why it goes through `APIClient`
///
/// Because every policy the app has about talking to its server has to apply to
/// this request too, and all of them live behind that one seam: the pinned
/// session, the App Attest assertion, the token refresh, the idempotency header.
/// An uploader that built its own `URLSession` would be the one request in the
/// app an attacker in the middle could answer — and it would look identical in a
/// diff to one that could not. `Tools/assert-pinned-sessions.py` fails on the
/// attempt.
///
/// ## Why the request is unauthenticated
///
/// `requiresAuth: false`. A crash is not a thing a signed-in user does: the
/// process that died may have died before the first screen, during a sign-out, or
/// with a refresh token the server has since revoked. Requiring a token would
/// make the reports from exactly those launches unsendable, and they are the
/// launches most worth hearing about. The server learns which install a report
/// came from from the attestation header the transport attaches anyway, which is
/// a stronger claim than a bearer token: it says the request came from a genuine
/// install of this app, which is the property a public crash endpoint needs.
///
/// ## Why the digest is the idempotency key
///
/// A report's upload is retried across launches, and the failure that most often
/// causes a retry — a response lost on the way back — is indistinguishable from a
/// report that never arrived. The digest is derived from the report's content, so
/// every attempt of one report carries one key, and the server collapses the
/// repeat instead of counting the crash twice. `docs/idempotency.md` is the
/// general version of this argument; this is the one place in the app where the
/// repeat is separated from the original by a process launch.
package struct APICrashReportUploader: CrashReportUploading {

    /// Where reports go. One path, stated once.
    package static let path = "/diagnostics/reports"

    private let client: any APIClient

    /// - Parameter client: The app's transport. No default: whether crash reports
    ///   go to the same server as everything else, over the same pinned session,
    ///   is the composition root's decision.
    package init(client: any APIClient) {
        self.client = client
    }

    package func upload(_ report: CrashReport) async -> CrashReportUploadOutcome {
        let endpoint: APIEndpoint
        do {
            endpoint = try APIEndpoint.post(
                APICrashReportUploader.path,
                body: report,
                requiresAuth: false,
                idempotencyKey: IdempotencyKey(rawValue: report.digest)
            )
        } catch {
            // The report did not encode. Nothing about the transport is wrong and
            // retrying will produce the same bytes, so this is a rejection rather
            // than a deferral — the alternative is one unencodable report at the
            // front of the queue blocking every later one for the life of the
            // install.
            return .rejected(reason: "could not encode: \(error)")
        }

        do {
            _ = try await client.sendEmpty(endpoint)
            return .accepted
        } catch let error as APIError {
            return APICrashReportUploader.outcome(for: error)
        } catch {
            return .deferred(reason: "\(error)")
        }
    }

    /// Which failures mean "never" and which mean "not now".
    ///
    /// Exhaustive rather than defaulted, so that a new `APIError` case is a build
    /// error here. The safe answer is `deferred` and a `default` would supply it
    /// automatically — which is the problem: a new permanent failure would quietly
    /// become a report retried at every launch for the life of the install.
    ///
    /// `decodingFailed` is **accepted**, and that is not defensive coding — it is
    /// the normal path for this endpoint. `sendEmpty` decodes `EmptyResponse` from
    /// the response body, an empty body is not valid JSON, and the correct answer
    /// to "here is a crash report" is `204 No Content`. So the success case
    /// arrives here as a decoding failure, and in every other reading of it the
    /// status code already said the report was taken: re-sending it would report
    /// one crash twice to satisfy a parser.
    ///
    /// `unauthorized` is permanent, which is the one place this differs from the
    /// rest of the app. The request is unauthenticated by design, so a 401 is the
    /// endpoint refusing the report rather than a token that a refresh could fix —
    /// and `URLSessionAPIClient` does not attempt a refresh for a request with
    /// `requiresAuth: false`, so deferring would retry the identical request.
    package static func outcome(for error: APIError) -> CrashReportUploadOutcome {
        switch error {
        case .httpError(let statusCode, _):
            APICrashReportUploader.outcome(forStatus: statusCode)
        case .unauthorized:
            .rejected(reason: "HTTP 401")
        case .invalidURL:
            .rejected(reason: "the request URL could not be formed")
        case .decodingFailed:
            .accepted
        case .invalidResponse, .networkUnavailable, .tokenRefreshFailed:
            .deferred(reason: error.localizedDescription)
        }
    }

    /// 4xx is permanent except for the two codes that ask to be retried.
    ///
    /// A 408 and a 429 are the server saying "later", so folding the whole 4xx
    /// range into `rejected` would throw a crash report away because the server
    /// was busy. Everything else in the range is the server saying this document
    /// is wrong, which a later launch does not change.
    private static func outcome(forStatus statusCode: Int) -> CrashReportUploadOutcome {
        let asksForRetry = statusCode == 408 || statusCode == 429
        guard (400..<500).contains(statusCode), !asksForRetry else {
            return .deferred(reason: "HTTP \(statusCode)")
        }
        return .rejected(reason: "HTTP \(statusCode)")
    }
}
