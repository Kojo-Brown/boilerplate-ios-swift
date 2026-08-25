import Core
import Foundation

// MARK: - Retrying decorator

/// Retries a repository call that failed for a reason another attempt could
/// answer, and bounds every attempt with a deadline.
///
/// This is the caller Phase 7 shipped `Retry` and `withTimeout` without.
/// `docs/solid.md` finding 7 records why there wasn't one: the only retry
/// policy in the package — refresh the token on a 401 and send the request
/// again — was welded into `URLSessionAPIClient.performRequest`, and the spec
/// noted that wiring in a second one "is a decision about which endpoints are
/// idempotent", with nowhere to express that decision. This type is that place.
/// The 401 refresh stays in transport, where it belongs: it is a property of
/// the credential the request carries, not of the profile operation being
/// retried, and every `APIClient` caller needs it, not just this repository.
///
/// ## The decision the policy split encodes
///
/// `UserRepository` has three operations against two HTTP methods that differ
/// in what a repeated call costs.
///
/// `fetchCurrentUser` is a `GET` and `deleteAccount` is a `DELETE`. Both are
/// idempotent: repeating them converges on the same server state, so a failure
/// that might be transient is worth another attempt whatever caused it.
///
/// `updateProfile` is a `PATCH`, and it is the interesting one. A `PATCH` whose
/// response was lost may have been applied — the request reached the server,
/// the server acted on it, and the reply died on the way back. Retrying it is
/// safe here only because nothing distinguishes "applied twice" from "applied
/// once" for a field assignment, and that is a fact about *this* endpoint, not
/// about `PATCH`. So the write policy retries only failures that prove the
/// request was **never delivered**: no connection to the internet, no route to
/// the host, no DNS answer, no TCP connection. Every one of those fails before
/// a byte of the request is written.
///
/// Deliberately outside that set, because none of them is evidence of anything:
///
/// * `URLError(.timedOut)` and `.networkConnectionLost` — the connection
///   existed. The request may have been delivered and the answer lost.
/// * `TimedOutError` from this type's own per-attempt deadline — same, and it
///   is even weaker evidence: the deadline is the client's opinion about how
///   long is too long.
/// * `503`, `504`, `429` — the server answered, so it received the request.
///   Whether it acted on it before answering is not something the status code
///   says.
///
/// A retry budget for those needs an idempotency key that lets the server
/// collapse a duplicate, which is Phase 9 item 5 and not a decorator.
///
/// ## What the deadline does, and what it does not
///
/// `withTimeout` wraps each attempt, not the sequence: three attempts under a
/// 15-second deadline are bounded at roughly 45 seconds plus backoff, and a
/// total budget is a different thing that this type does not offer. Its own
/// documentation is emphatic that a timeout stops *waiting* rather than
/// stopping work — cancellation is cooperative, and an operation that never
/// checks for it runs to completion regardless. Underneath this decorator the
/// operation is `URLSession.data(for:)`, which does honour cancellation, so
/// here the deadline genuinely stops the request. That is a property of what
/// this happens to wrap and not a guarantee of the combinator.
///
/// The one composition detail worth stating out loud: `Retry.isTransient`
/// predates `withTimeout` having any caller, so it does not know
/// `TimedOutError` and classifies it — like every type it does not recognise —
/// as not worth retrying. Composing the two means saying so, which is what
/// `isRetryableIdempotent` is for. Without it, a per-attempt deadline would
/// make the *first* slow attempt terminal and quietly disable retrying for
/// precisely the failure retrying exists to absorb.
package struct RetryingUserRepository: UserRepositoryDecorator {

    // MARK: - Defaults

    /// Attempts for `fetchCurrentUser` and `deleteAccount`, including the
    /// first.
    package static let defaultIdempotentPolicy = Retry.Policy(
        maxAttempts: 3,
        isRetryable: RetryingUserRepository.isRetryableIdempotent
    )

    /// Attempts for `updateProfile`. Two, not three: the only failures it
    /// retries are ones that happened before the request left the device, and a
    /// device that has no route to the host on two consecutive tries a backoff
    /// apart is offline rather than unlucky.
    package static let defaultNonIdempotentPolicy = Retry.Policy(
        maxAttempts: 2,
        isRetryable: RetryingUserRepository.isUndelivered
    )

    /// The deadline on a single attempt.
    ///
    /// Comfortably under `URLSession`'s own 60-second request timeout, so this
    /// is the deadline that fires and the one whose duration a reader can find.
    package static let defaultAttemptTimeout: Duration = .seconds(15)

    // MARK: - Stored

    package let base: any UserRepository

    private let idempotentPolicy: Retry.Policy
    private let nonIdempotentPolicy: Retry.Policy
    private let attemptTimeout: Duration
    private let randomness: Backoff.UnitRandom
    private let sleep: Retry.Sleep

    /// `base` carries no default: it is the collaborator, and
    /// `docs/solid.md` finding 1 is what a default there rebuilds.
    ///
    /// Everything else does, for the reason `URLSessionAPIClient` states about
    /// its `session` and `decoder` — a policy is configuration rather than a
    /// collaborator, none of it appears in the audited surface, and `randomness`
    /// and `sleep` exist so a suite can assert the schedule without spending it.
    package init(
        base: any UserRepository,
        idempotentPolicy: Retry.Policy = RetryingUserRepository.defaultIdempotentPolicy,
        nonIdempotentPolicy: Retry.Policy = RetryingUserRepository.defaultNonIdempotentPolicy,
        attemptTimeout: Duration = RetryingUserRepository.defaultAttemptTimeout,
        randomness: @escaping Backoff.UnitRandom = Backoff.systemRandom,
        sleep: @escaping Retry.Sleep = Retry.taskSleep
    ) {
        precondition(attemptTimeout > .zero, "attemptTimeout must be positive, got \(attemptTimeout)")
        self.base = base
        self.idempotentPolicy = idempotentPolicy
        self.nonIdempotentPolicy = nonIdempotentPolicy
        self.attemptTimeout = attemptTimeout
        self.randomness = randomness
        self.sleep = sleep
    }

    // MARK: - UserRepository

    package func fetchCurrentUser() async throws -> User {
        let base = self.base
        return try await run(idempotentPolicy) { try await base.fetchCurrentUser() }
    }

    package func updateProfile(name: String) async throws -> User {
        let base = self.base
        return try await run(nonIdempotentPolicy) { try await base.updateProfile(name: name) }
    }

    package func deleteAccount() async throws {
        let base = self.base
        try await run(idempotentPolicy) { try await base.deleteAccount() }
    }

    // MARK: - The loop

    /// One attempt, one deadline, `policy` deciding whether there is another.
    private func run<Value: Sendable>(
        _ policy: Retry.Policy,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let attemptTimeout = self.attemptTimeout
        return try await Retry.run(policy, randomness: randomness, sleep: sleep) { _ in
            try await withTimeout(attemptTimeout) { try await operation() }
        }
    }

    // MARK: - Classification

    /// `Retry.isTransient`, plus the deadline this type imposes itself.
    ///
    /// An attempt that ran out of time is the canonical retryable failure — it
    /// is what a saturated connection looks like from the client — and it is
    /// invisible to a classifier written before anything called `withTimeout`.
    package static let isRetryableIdempotent: @Sendable (any Error) -> Bool = { error in
        error is TimedOutError || Retry.isTransient(error)
    }

    /// `true` only for failures that prove the request was never delivered.
    ///
    /// The direction of the default matters more here than the contents of the
    /// list: an unrecognised failure is not retried, so a `URLError` code added
    /// to Foundation tomorrow costs one avoidable failure rather than a
    /// duplicated write.
    package static let isUndelivered: @Sendable (any Error) -> Bool = { error in
        guard let code = RetryingUserRepository.transportCode(of: error) else { return false }
        switch code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            // Each of these fails while establishing the connection, so no part
            // of the request has been written to a socket.
            return true
        default:
            // `.timedOut` and `.networkConnectionLost` land here on purpose:
            // both mean a connection existed, and neither says whether the
            // server acted before it went away.
            return false
        }
    }

    /// The transport failure behind an error, however it is wrapped.
    ///
    /// Two spellings, because the layer genuinely produces two: transport
    /// throws a bare `URLError`, and `URLSessionAPIClient` boxes it as
    /// `APIError.networkUnavailable`. `UserRepositoryError.networkUnavailable`
    /// is not matched — it is the doubles' vocabulary
    /// (`docs/solid.md` finding 4), it carries no `URLError`, and treating a
    /// case with no cause attached as proof of non-delivery would be inventing
    /// the evidence this classifier exists to demand.
    private static func transportCode(of error: any Error) -> URLError.Code? {
        if let urlError = error as? URLError {
            return urlError.code
        }
        if let apiError = error as? APIError, case let .networkUnavailable(urlError) = apiError {
            return urlError.code
        }
        return nil
    }
}
