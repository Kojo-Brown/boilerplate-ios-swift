import Foundation

/// Runs work off the main actor and lets only the newest run's result back onto
/// it. Anything a later call superseded is cancelled and its outcome discarded.
///
/// This is the hop *back*. `OffMainActor.run` covers leaving the main actor
/// safely; the harder half is returning to it, because the `await` that left
/// also released it. Other main-actor work ran in the meantime — very often a
/// second call to the same method — so "assign the result when it arrives" is
/// only correct if this result is still the one anybody wants.
///
/// The shape is search-as-you-type, but it is every screen with a refreshable
/// list, a segmented filter, or a pull-to-refresh beside an auto-refresh:
///
/// ```swift
/// @Observable
/// @MainActor
/// final class SearchViewModel {
///     private(set) var hits: [Hit] = []
///     private(set) var errorMessage: String?
///     private let search = LatestOnlyTask<[Hit]>()
///     private let api: any SearchAPI
///
///     func queryChanged(_ text: String) async {
///         do {
///             // Each keystroke supersedes the request before it. A response
///             // that arrives after a newer query was issued never lands.
///             guard let found = try await search.run({ [api] in
///                 try await api.hits(matching: text)
///             }) else {
///                 return   // superseded: a newer query owns the screen now
///             }
///             hits = found
///         } catch {
///             errorMessage = error.localizedDescription
///         }
///     }
/// }
/// ```
///
/// ## The bug this exists to remove
///
/// Written the obvious way, the method above is wrong in a way that testing by
/// hand rarely surfaces:
///
/// ```swift
/// func queryChanged(_ text: String) async {
///     hits = try await api.search(text)   // ← whoever finishes last wins
/// }
/// ```
///
/// Nothing there is a data race, and Swift 6 compiles it without complaint: the
/// assignment happens on the main actor, and it is a single statement, so there
/// is no invariant visibly spanning the `await`. The defect is ordering.
/// Requests are not answered in the order they are sent, so typing "sw" then
/// "swift" leaves the list showing results for "sw" whenever the shorter query
/// happens to be slower — a stale-looking screen with a healthy network log,
/// which is why it usually ships.
///
/// Two things follow, and both are here:
///
/// **Supersede explicitly.** A new run cancels the one in flight rather than
/// racing it. Cancellation is cooperative, so this is a request, not a
/// guarantee — which is exactly why it cannot be the only defence.
///
/// **Decide by generation, not by cancellation.** Each run takes a ticket before
/// it suspends and re-reads the counter when it resumes. Only the run holding
/// the current ticket may return a value; every other one returns `nil` however
/// it finished. That covers the case `Task.isCancelled` cannot: an operation
/// that never checks for cancellation — a `URLSession` call already past its
/// last cancellation point, or any third-party SDK — runs to completion and
/// produces a perfectly good, entirely stale result. `LatestOnlyTaskTests`
/// exercises that path against an operation written to ignore cancellation
/// outright.
///
/// ## Reentrancy is the mechanism, not a hazard here
///
/// Two calls can be in `run` at once precisely because the first one's `await`
/// releases the main actor. That is what lets the second call arrive, bump the
/// counter, and cancel the first — the type is built on main-actor reentrancy
/// rather than defending against it. The generation counter is read and written
/// only in the synchronous stretches between suspensions, so no two runs can
/// interleave inside the claim itself.
@MainActor
final class LatestOnlyTask<Success: Sendable> {
    /// The run that has not yet been superseded, kept so a later call can cancel it.
    private var inFlight: Task<Success, any Error>?

    /// Ticket issued to each run. Wrapping arithmetic keeps it from trapping in
    /// a process that outlives `UInt64.max` runs, which nothing will.
    private var generation: UInt64 = 0

    /// Whether a run that has not been superseded or cancelled is still going.
    ///
    /// Suitable for driving a spinner: it goes `false` when the newest run
    /// finishes, and a superseded run finishing does not clear it.
    var isRunning: Bool { inFlight != nil }

    init() {}

    /// Runs `operation` off the main actor, superseding any run already in flight.
    ///
    /// - Parameter operation: The work to perform. `@Sendable` because it runs
    ///   away from the main actor — see `OffMainActor` for why that annotation
    ///   is what makes the hop happen rather than merely describing it.
    /// - Returns: The result, or `nil` if a later call superseded this run
    ///   before it finished. A superseded run reports `nil` whether it succeeded,
    ///   failed, or was cancelled; its outcome is no longer anybody's business.
    /// - Throws: Whatever `operation` threw, but only while this run is still
    ///   the current one.
    @discardableResult
    func run(
        _ operation: @escaping @Sendable () async throws -> Success
    ) async throws -> Success? {
        // Claim, cancel and record: all synchronous, so no other call can
        // interleave between taking the ticket and publishing the task. The
        // same discipline `SingleFlightCache` uses to make its lookup atomic.
        inFlight?.cancel()
        generation &+= 1
        let ticket = generation

        let task = Task { try await OffMainActor.run(operation) }
        inFlight = task

        do {
            let value = try await task.value
            guard isCurrent(ticket) else { return nil }
            inFlight = nil
            return value
        } catch {
            guard isCurrent(ticket) else { return nil }
            inFlight = nil
            throw error
        }
    }

    /// Cancels the run in flight and discards its result when it finishes.
    ///
    /// The caller awaiting that run receives `nil`, the same as if a newer run
    /// had superseded it — which is what happened, minus the newer run.
    func cancel() {
        inFlight?.cancel()
        inFlight = nil
        generation &+= 1
    }

    /// Whether `ticket` is still the newest one issued.
    ///
    /// Read after the `await` returns, never before it: the answer before the
    /// suspension is not evidence about the answer after it.
    private func isCurrent(_ ticket: UInt64) -> Bool {
        ticket == generation
    }
}
