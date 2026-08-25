import Core
import Foundation
import os

// MARK: - What is recorded

/// The repository operation a record is about.
///
/// A closed enum rather than the function name as a string: a suite can switch
/// over it exhaustively, and an operation added to `UserRepository` tomorrow is
/// a compile error here rather than a typo nobody notices in a log.
package enum RepositoryOperation: String, Sendable, CaseIterable {
    case fetchCurrentUser
    case updateProfile
    case deleteAccount
}

/// How a repository call ended.
package enum RepositoryOutcome: Sendable, Equatable {
    case succeeded
    /// A bounded label for the failure — never the error's message. See
    /// `label(for:)`.
    case failed(String)
    /// The caller went away. Not a failure, and counting it as one is how a
    /// dashboard learns to panic every time a user swipes back.
    case cancelled
}

extension RepositoryOutcome {

    /// A short, bounded, non-identifying label for a failure.
    ///
    /// `localizedDescription` is deliberately not used, and this is the whole
    /// reason this function exists rather than the obvious one-liner. A
    /// localised description is written for a person looking at a screen: it
    /// interpolates whatever the underlying error carried, which for a
    /// `URLError` includes the failing URL — query string, and any token in it,
    /// included. `DiagnosticRecord` already states the rule this follows: a
    /// diagnostic string outlives the process and is routinely attached to bug
    /// reports, so treat everything in it as published.
    ///
    /// What comes out instead is drawn from a finite set: an error case name, a
    /// status code, or a `URLError` code number. All three are useful for
    /// grouping and none of them can carry a credential.
    package static func label(for error: any Error) -> String {
        switch error {
        case let apiError as APIError:
            return apiLabel(for: apiError)
        case let urlError as URLError:
            return "transport(\(urlError.code.rawValue))"
        case let repositoryError as UserRepositoryError:
            return String(describing: repositoryError)
        case is TimedOutError:
            return "attemptTimedOut"
        default:
            // The type name, which is bounded by the source, where the value
            // would not be.
            return String(describing: type(of: error))
        }
    }

    private static func apiLabel(for error: APIError) -> String {
        // Spelled out case by case rather than with a `default`, so a new
        // `APIError` has to be given a label here instead of silently
        // inheriting one.
        switch error {
        case .invalidURL:
            return "invalidURL"
        case .invalidResponse:
            return "invalidResponse"
        case .unauthorized:
            return "unauthorized"
        case .tokenRefreshFailed:
            return "tokenRefreshFailed"
        case let .httpError(statusCode, _):
            // The status code, not the body. The body is the server's message
            // to a developer and can contain anything at all.
            return "http(\(statusCode))"
        case .decodingFailed:
            // Not the associated message: it is a `DecodingError` description,
            // which names the key path that failed and, for a type mismatch,
            // quotes what was found there.
            return "decodingFailed"
        case let .networkUnavailable(urlError):
            return "transport(\(urlError.code.rawValue))"
        }
    }
}

/// One completed repository call.
package struct RepositoryCall: Sendable, Equatable {
    package let operation: RepositoryOperation
    package let outcome: RepositoryOutcome
    /// Measured on a monotonic clock, so it is a duration and not the
    /// difference between two wall-clock readings that a time-zone change or an
    /// NTP correction can make negative.
    package let duration: Duration

    /// The duration in whole milliseconds, rounded.
    ///
    /// `Duration` renders as `0.812 seconds`, which sorts and groups badly in a
    /// log. The arithmetic goes through `Double` because `components` is a pair
    /// of `Int64`s in seconds and attoseconds, and attoseconds do not divide
    /// into milliseconds in `Int64` without overflowing on the way.
    package var durationMilliseconds: Int {
        let parts = duration.components
        let total = Double(parts.seconds) * 1000 + Double(parts.attoseconds) * 1e-15
        return Int(total.rounded())
    }

    /// The one-line rendering used by every sink.
    package var summary: String {
        let outcomeLabel: String
        switch outcome {
        case .succeeded:
            outcomeLabel = "ok"
        case .cancelled:
            outcomeLabel = "cancelled"
        case let .failed(label):
            outcomeLabel = "failed(\(label))"
        }
        return "\(operation.rawValue) \(outcomeLabel) in \(durationMilliseconds)ms"
    }
}

// MARK: - The sink

/// Where `TelemetryUserRepository` sends what it measured.
///
/// `record` is `async` and cannot throw. Both halves are deliberate.
///
/// **Async**, because the interesting sinks are isolated: the app's own
/// `DiagnosticJournal` lives on `@DiagnosticsActor`, and a synchronous
/// requirement would force any such implementation to hop through an
/// unstructured `Task` — which, as `DiagnosticsActor` documents, silently
/// destroys the one property a journal has, since two `Task`s racing to the
/// same domain can arrive in either order. Awaiting the record keeps the
/// caller's program order.
///
/// **Non-throwing**, because a repository call must not fail on account of
/// being measured. A sink that cannot write drops the record; it does not turn
/// a successful profile fetch into a failure.
package protocol RepositoryTelemetry: Sendable {
    func record(_ call: RepositoryCall) async
}

// MARK: - Live sink

/// Writes one line per call to the unified log.
///
/// `os.Logger` rather than this package's `DiagnosticJournal`: the journal is a
/// bounded in-memory buffer whose terminal operation is a file write, built for
/// the handful of events that belong in a bug report, and a line per repository
/// call is not that. The unified log is already the place the system puts this
/// class of signal, it is off the process's critical path, and `log stream`
/// reads it without the app having to flush anything.
///
/// Every interpolation is marked `.public`. The default for a non-literal is
/// `.private`, which redacts it to `<private>` in a release build — correct as a
/// default and wrong for these values specifically, because
/// `RepositoryOutcome.label(for:)` exists precisely to guarantee that nothing
/// identifying reaches this line.
package struct OSLogRepositoryTelemetry: RepositoryTelemetry {

    private let logger: Logger

    /// - Parameters:
    ///   - subsystem: Usually the bundle identifier; the composition root
    ///     decides, because a subsystem is how a log filter finds this app.
    ///   - category: The log category. Configuration rather than a
    ///     collaborator, so it keeps a default.
    package init(subsystem: String, category: String = "repository") {
        logger = Logger(subsystem: subsystem, category: category)
    }

    /// A failure is logged at `.error` and everything else at `.debug`.
    ///
    /// That is a retention decision, not a formatting one: the unified log
    /// persists `.error` to disk and discards `.debug` unless something is
    /// actively streaming. A repository call that worked is worth watching live
    /// and is not worth storing; one that failed is worth having after the
    /// fact, in the sysdiagnose from the user who reported it.
    package func record(_ call: RepositoryCall) async {
        switch call.outcome {
        case .failed:
            logger.error("\(call.summary, privacy: .public)")
        case .succeeded, .cancelled:
            logger.debug("\(call.summary, privacy: .public)")
        }
    }
}

// MARK: - Double

/// Keeps every record in memory, in order, for a test or a debug screen to read
/// back.
///
/// Lock-backed rather than `@unchecked Sendable` over a bare array, which is
/// the discipline `SendableConformanceTests` exists to hold the doubles to.
package final class RecordingRepositoryTelemetry: RepositoryTelemetry {

    private let entries = OSAllocatedUnfairLock<[RepositoryCall]>(initialState: [])

    package init() {}

    /// Every call recorded so far, oldest first.
    package var calls: [RepositoryCall] { entries.withLock { $0 } }

    /// The operations recorded so far, oldest first.
    package var operations: [RepositoryOperation] { calls.map(\.operation) }

    /// The outcomes recorded so far, oldest first.
    package var outcomes: [RepositoryOutcome] { calls.map(\.outcome) }

    package func record(_ call: RepositoryCall) async {
        entries.withLock { $0.append(call) }
    }
}
