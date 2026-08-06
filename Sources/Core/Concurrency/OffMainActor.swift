import Foundation

/// The hop off the main actor, written down once so that call sites can say what
/// they mean.
///
/// ```swift
/// @MainActor
/// func present(_ payload: Data) async {
///     // Parsing is expensive and pure. It runs on the cooperative pool, and
///     // this method resumes on the main actor with the result in hand.
///     let report = await OffMainActor.run { Report.parse(payload) }
///     self.report = report
/// }
/// ```
///
/// ## Why a helper, when it is one `await`
///
/// Because the three constructs people reach for instead mostly do not work, and
/// none of them looks wrong. The rule this type encodes is that *only a
/// `nonisolated async` function changes where code runs.*
///
/// **`Task { }` does not move anything off the main actor.** A closure literal
/// passed to `Task.init` inherits the enclosing actor — that is what
/// `@_inheritActorContext` on the parameter does — so a `Task { }` written
/// inside a `@MainActor` method runs its body *on the main actor*. What it buys
/// is concurrency with respect to the caller: the method returns without waiting
/// for it. It buys none with respect to the main thread. A 200 ms parse inside
/// one is still 200 ms of dropped frames, now at an unpredictable moment.
///
/// **A `nonisolated` *synchronous* function does not either.** `nonisolated`
/// states that a declaration does not need the actor's isolation. It says
/// nothing about where it executes, and a synchronous call is a jump rather than
/// a scheduling decision: it runs wherever the caller already is. Called from
/// the main actor, a `nonisolated func` body runs on the main actor.
///
/// **A `nonisolated` *async* function does.** Since SE-0338 a nonisolated async
/// function runs on the generic concurrent executor instead of inheriting its
/// caller's actor. That is the entire mechanism here: `run` is nonisolated and
/// `async`, so awaiting it from the main actor releases the main actor and
/// continues on the cooperative pool.
///
/// The `@Sendable` on `work` is load-bearing rather than decorative. A
/// non-`@Sendable`, non-escaping closure literal formed inside a `@MainActor`
/// method is inferred to be `@MainActor`-isolated, and passing one here would
/// put the body straight back on the main actor while the signature claimed
/// otherwise. `@Sendable` closures do not inherit isolation, so the annotation
/// is what makes the hop real. It also states the requirement honestly: the body
/// runs somewhere else, so it must not touch anything that belongs here.
///
/// ## What this is not
///
/// It is a hop, not a fork. `run` stays inside the caller's task, so the caller
/// is suspended for the duration and nothing runs in parallel with it. That is
/// usually what a view model wants — the alternative is state changing under a
/// method that is midway through reading it — but when the point is to do two
/// things at once, the tool is `async let` or a task group, not this.
///
/// Staying inside the caller's task is also the difference from
/// `Task.detached { }`, which does leave the main actor and is the wrong reach
/// nine times out of ten. A detached task is unstructured and inherits nothing:
/// not the caller's priority, not its task-local values, and not its
/// cancellation, so cancelling the caller leaves the work running. `run`
/// inherits all three because it never left the task. Reach for `Task.detached`
/// when the work genuinely has to outlive the thing that started it.
///
/// ## After the `await`
///
/// Execution resumes on the main actor, which is the half that gets missed. The
/// suspension released the main actor, so other main-actor work ran while this
/// was off doing its own — a value read before the hop may be stale after it,
/// and a newer request may already have superseded this one. That is the same
/// "an `await` is a hole in your invariant" rule that actor reentrancy imposes,
/// and the main actor is not exempt from it. `LatestOnlyTask` is the guard for
/// the common form of it.
enum OffMainActor {
    /// Runs `work` off the main actor and returns its result to the caller.
    ///
    /// Both the caller's priority and its cancellation propagate into `work`,
    /// because this does not start a new task — it is the caller's own task,
    /// executing somewhere else for a while.
    ///
    /// - Parameter work: The work to run away from the main actor. It is
    ///   `@Sendable` because it does not run under the caller's isolation, so it
    ///   must not capture anything the caller's actor protects. A synchronous
    ///   closure is accepted here too, which is the common case: expensive pure
    ///   computation that has no business on the main thread.
    /// - Returns: Whatever `work` returned, delivered back on the caller's actor.
    static func run<Success: Sendable>(
        _ work: @Sendable () async throws -> Success
    ) async rethrows -> Success {
        try await work()
    }
}
