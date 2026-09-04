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
/// the server acted on it, and the reply died on the way back. Which failures
/// are worth another attempt therefore depends on whether the request carries
/// something the server can recognise a repeat by, and since Phase 9 item 5 it
/// does: `updateProfile` takes an ``IdempotencyKey``, minted once per logical
/// edit in `UserRepository.updateProfile(name:)` and forwarded unchanged to
/// every attempt this type makes.
///
/// That is what ``defaultKeyedWritePolicy`` spends. With the key on the
/// request, a timeout, a lost connection and a 503 stop being evidence the
/// client has to interpret: whatever happened on the server the first time,
/// the second request is answered from the record of the first rather than
/// executed again. So the write takes the same classification as a read.
///
/// **This is a claim about the server, and it is the only one this package
/// makes.** If the API ignores `Idempotency-Key`, the widened policy is a
/// double-write waiting for a slow afternoon. ``defaultUnkeyedWritePolicy`` is
/// kept for exactly that case and is a one-argument change at the composition
/// root: it retries only failures that prove the request was **never
/// delivered** — no connection to the internet, no route to the host, no DNS
/// answer, no TCP connection, each of which fails before a byte is written to a
/// socket — and refuses the rest, because none of them is evidence of anything:
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
/// One duplicate remains outside both policies and is worth knowing about:
/// `URLSessionAPIClient` re-sends a request once on a 401 to retry it with a
/// refreshed token, which this type sees as a single call. The key covers it —
/// the refresh retry copies the original request, headers included — which is
/// the one part of this mechanism that pays off even under the unkeyed policy.
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

    /// Attempts for `updateProfile` as this package sends it: with an
    /// `Idempotency-Key` the server is expected to collapse a duplicate on.
    ///
    /// Identical to ``defaultIdempotentPolicy``, and that is the point rather
    /// than an economy — a keyed write is, from the retry loop's side, exactly
    /// as repeatable as a read. The two are separate constants because they
    /// answer different questions: this one can be swapped for
    /// ``defaultUnkeyedWritePolicy`` without touching how reads behave, and the
    /// day they diverge nobody has to work out which callers meant which.
    package static let defaultKeyedWritePolicy = Retry.Policy(
        maxAttempts: 3,
        isRetryable: RetryingUserRepository.isRetryableIdempotent
    )

    /// Attempts for `updateProfile` against an API that does **not** honour
    /// `Idempotency-Key`.
    ///
    /// Two, not three: the only failures it retries are ones that happened
    /// before the request left the device, and a device that has no route to the
    /// host on two consecutive tries a backoff apart is offline rather than
    /// unlucky.
    ///
    /// Nothing in this package selects it. It is here so that "our server
    /// ignores the header" is a line in `AppContainer` rather than a rewrite of
    /// this file, and so the safe classification stays under test — see
    /// `IdempotencyTests`.
    package static let defaultUnkeyedWritePolicy = Retry.Policy(
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
    private let writePolicy: Retry.Policy
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
        writePolicy: Retry.Policy = RetryingUserRepository.defaultKeyedWritePolicy,
        attemptTimeout: Duration = RetryingUserRepository.defaultAttemptTimeout,
        randomness: @escaping Backoff.UnitRandom = Backoff.systemRandom,
        sleep: @escaping Retry.Sleep = Retry.taskSleep
    ) {
        precondition(attemptTimeout > .zero, "attemptTimeout must be positive, got \(attemptTimeout)")
        self.base = base
        self.idempotentPolicy = idempotentPolicy
        self.writePolicy = writePolicy
        self.attemptTimeout = attemptTimeout
        self.randomness = randomness
        self.sleep = sleep
    }

    // MARK: - UserRepository

    package func fetchCurrentUser() async throws -> User {
        let base = self.base
        return try await run(idempotentPolicy) { try await base.fetchCurrentUser() }
    }

    /// The key is captured, not re-derived: every attempt below sends the one
    /// this call was handed. That is the entire reason the loop is allowed to
    /// run more than once for a write.
    package func updateProfile(name: String, idempotencyKey: IdempotencyKey) async throws -> User {
        let base = self.base
        return try await run(writePolicy) {
            try await base.updateProfile(name: name, idempotencyKey: idempotencyKey)
        }
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
    /// The classification behind ``defaultUnkeyedWritePolicy``: what a write
    /// may retry when nothing on the request lets the server collapse a
    /// duplicate.
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
