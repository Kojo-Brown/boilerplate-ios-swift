import Core
import Foundation

// MARK: - Telemetry decorator

/// Times every repository call and reports how it ended, without changing what
/// the call does or what it throws.
///
/// The decorator that best shows why the pattern is worth the indirection:
/// there is nothing here a `Logger` call at the top and bottom of each method
/// in `LiveUserRepository` could not do, and doing it that way would put
/// measurement inside the type being measured, where it would be copied into
/// the next repository and forgotten in the one after that.
///
/// ## Where this sits, and what that decides
///
/// `AppContainer` puts it outermost, so what it measures is what the *caller*
/// experienced: retries, backoff sleeps and cache hits all inside the number.
/// A screen that took 4 seconds to show a profile is 4 seconds here, which is
/// the figure a person complaining about the app is describing.
///
/// The other placement is just as defensible and answers a different question.
/// Innermost — between the cache and the retry loop — it would record one entry
/// per transport attempt, so three retries would be three records and a cache
/// hit would be none, which is what a request-rate or error-budget dashboard
/// wants. The two are not interchangeable, and nothing about the type says
/// which one is in force. That is the point worth taking from this file: with
/// decorators, ordering *is* the configuration, and it is decided in one
/// readable place instead of being implied by where somebody put a log line.
///
/// Under the current order a cache hit is indistinguishable from a very fast
/// remote answer, save for costing under a millisecond. If telling them apart
/// ever matters, the honest fix is a second instance of this decorator inside
/// the cache rather than a `cacheHit` flag threaded through `UserRepository` —
/// the protocol describes profile operations, not how they were served.
package struct TelemetryUserRepository: UserRepositoryDecorator {

    package let base: any UserRepository

    private let telemetry: any RepositoryTelemetry
    private let now: @Sendable () -> ContinuousClock.Instant

    /// - Parameters:
    ///   - base: The repository this one measures.
    ///   - telemetry: Where the records go.
    ///   - now: The clock. `ContinuousClock` keeps running while the device is
    ///     suspended, which is the honest reading for "how long did the user
    ///     wait"; it is injected so a suite can assert an exact duration
    ///     instead of a range.
    package init(
        base: any UserRepository,
        telemetry: any RepositoryTelemetry,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.base = base
        self.telemetry = telemetry
        self.now = now
    }

    // MARK: - UserRepository

    package func fetchCurrentUser() async throws -> User {
        let base = self.base
        return try await measure(.fetchCurrentUser) { try await base.fetchCurrentUser() }
    }

    package func updateProfile(name: String, idempotencyKey: IdempotencyKey) async throws -> User {
        let base = self.base
        return try await measure(.updateProfile) {
            try await base.updateProfile(name: name, idempotencyKey: idempotencyKey)
        }
    }

    package func deleteAccount() async throws {
        let base = self.base
        try await measure(.deleteAccount) { try await base.deleteAccount() }
    }

    // MARK: - Measurement

    /// Runs `work`, records what happened, and hands the outcome on unchanged.
    ///
    /// The error is rethrown exactly as it arrived — not wrapped, not
    /// translated, not replaced with something carrying the timing. A caller
    /// that catches `APIError` must not start missing failures because
    /// something upstream decided to measure them, and
    /// `aFailureIsRecordedAndRethrownUnchanged` is the pin on that.
    private func measure<Value: Sendable>(
        _ operation: RepositoryOperation,
        _ work: () async throws -> Value
    ) async throws -> Value {
        let started = now()
        do {
            let value = try await work()
            await record(operation, .succeeded, since: started)
            return value
        } catch {
            let outcome: RepositoryOutcome
            if TelemetryUserRepository.isCancellation(error) {
                outcome = .cancelled
            } else {
                outcome = .failed(RepositoryOutcome.label(for: error))
            }
            await record(operation, outcome, since: started)
            throw error
        }
    }

    private func record(
        _ operation: RepositoryOperation,
        _ outcome: RepositoryOutcome,
        since started: ContinuousClock.Instant
    ) async {
        await telemetry.record(
            RepositoryCall(
                operation: operation,
                outcome: outcome,
                duration: started.duration(to: now())
            )
        )
    }

    /// Whether a failure is really the caller having gone away.
    ///
    /// Two spellings again, and for the reason `Retry` documents: a
    /// `URLSession` task stopped by task cancellation reports
    /// `URLError(.cancelled)` rather than `CancellationError`, so a decorator
    /// that knew only the latter would file every dismissed screen as a
    /// transport failure.
    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        if let apiError = error as? APIError, case let .networkUnavailable(urlError) = apiError {
            return urlError.code == .cancelled
        }
        return false
    }
}
