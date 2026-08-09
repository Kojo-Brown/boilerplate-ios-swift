import Dispatch

/// A `SerialExecutor` that runs an actor's jobs on a serial `DispatchQueue` it
/// owns, instead of on the shared cooperative thread pool.
///
/// ```swift
/// @globalActor
/// actor DiagnosticsActor {
///     static let shared = DiagnosticsActor()
///     nonisolated let executor = SerialDispatchExecutor(label: "…diagnostics", qos: .utility)
///     nonisolated var unownedExecutor: UnownedSerialExecutor {
///         executor.asUnownedSerialExecutor()
///     }
/// }
/// ```
///
/// ## What a custom executor does *not* buy
///
/// It does not buy serialisation. Every actor is already serial — that is what
/// an actor is — so an actor with a custom serial executor runs one job at a
/// time exactly like an actor without one. Reaching for `SerialExecutor` to
/// "make something serial" is reaching for a tool the language already applied.
///
/// It does not buy ordering either. Neither executor promises that two
/// independently created tasks reach the actor in the order they were started:
/// the default actor executor drains its queue in *priority* order, and while a
/// serial `DispatchQueue` is FIFO with respect to `enqueue`, when each task
/// calls `enqueue` is still a scheduling detail. Anything that needs a total
/// order has to take it *inside* the domain, where the actor's own serialisation
/// supplies it — which is why `DiagnosticJournal` stamps its sequence number
/// there and not at the call site.
///
/// ## What it does buy
///
/// **A thread that is not the cooperative pool's.** The pool is sized to the
/// core count and has no spare threads by design: a job that blocks — an
/// `fsync`, a `read` on a slow volume, a lock held by something else — parks one
/// of those few threads for the duration and starves every other task on the
/// machine, including ones with no relationship to it. Swift's rule is that the
/// pool is for work that suspends, never for work that blocks. A domain whose
/// whole job is blocking I/O therefore needs somewhere else to run, and a serial
/// `DispatchQueue` is that somewhere: it is one thread, it is allowed to block,
/// and the cost of blocking it is bounded to the domain that chose to.
///
/// **A named, attributable execution context.** The queue label shows up in
/// crash reports, in `sample`, and in Instruments' thread list, so background
/// work has a name instead of appearing as another anonymous
/// `com.apple.root.user-initiated-qos` frame.
///
/// **A QoS ceiling for a whole domain.** Cooperative-pool work runs at the
/// enclosing task's priority, so a background domain called from a
/// `.userInitiated` task inherits that priority and competes with the work that
/// spawned it. Jobs here run at the QoS the queue was created with, whatever
/// the caller's priority — a domain-wide statement that this work is never
/// urgent. Dispatch may still boost the queue to resolve a priority inversion,
/// which is the behaviour you want and not a hole in the ceiling.
///
/// ## Interop, which is the other half of the reason
///
/// A `DispatchQueue`-backed domain can adopt code that already runs on that
/// queue. Callbacks delivered to it are, in fact, isolated to the actor, and
/// `checkIsolated()` below is what lets the runtime verify that claim — so an
/// `assumeIsolated` from inside such a callback is checked rather than assumed.
/// With the default executor there is no such queue to deliver to, and the same
/// bridge has to go through a `Task`, which loses the callback's ordering.
final class SerialDispatchExecutor: SerialExecutor {
    /// The queue every job enqueued here runs on.
    ///
    /// `autoreleaseFrequency: .workItem` because a job is a unit of work with a
    /// beginning and an end: draining per work item keeps autoreleased objects
    /// from accumulating for as long as the queue's thread happens to live,
    /// which for a queue this long-lived is the process.
    private let queue: DispatchQueue

    /// - Parameters:
    ///   - label: Reverse-DNS label for the queue. This is the name that appears
    ///     in crash reports and profiling tools, so it should identify the
    ///     domain rather than the type.
    ///   - qos: The quality of service every job on this executor runs at,
    ///     regardless of the priority of the task that enqueued it.
    init(label: String, qos: DispatchQoS = .utility) {
        queue = DispatchQueue(label: label, qos: qos, autoreleaseFrequency: .workItem)
    }

    /// The label of the backing queue, as it appears in a crash report.
    var label: String { queue.label }

    /// Schedules one unit of actor work on the queue.
    ///
    /// The conversion to `UnownedJob` is required, not stylistic. `ExecutorJob`
    /// is non-copyable and non-`Sendable`, so it cannot be captured by the
    /// escaping closure `DispatchQueue.async` takes; `UnownedJob` is the
    /// unmanaged handle that can be, and consuming the `ExecutorJob` to make one
    /// transfers the obligation to run it exactly once. Dropping the handle
    /// without running it would leak the job and hang whatever awaits it.
    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        queue.async {
            unownedJob.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    /// The reference the runtime holds to this executor while an actor uses it.
    ///
    /// `UnownedSerialExecutor` does not retain, which is safe here because the
    /// actor that installs this executor owns it as a stored `let` — the
    /// executor cannot outlive the reference and cannot predecease it either.
    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// Traps unless the caller is already running on this executor's queue.
    ///
    /// This is SE-0424's hook: `assumeIsolated` and `assertIsolated` cannot
    /// reason about a custom executor by themselves, so they ask it. Without an
    /// implementation the protocol's default traps unconditionally with
    /// "expected checkIsolated to be implemented", which turns every
    /// `assumeIsolated` on this domain into a crash — including the ones that
    /// were correct.
    ///
    /// It carries no availability annotation on purpose. The protocol
    /// *requirement* it satisfies is gated to the Swift 6 runtime, and a witness
    /// may always be more available than its requirement; annotating this to
    /// match would only stop it from being callable directly on iOS 17, which
    /// the tests do.
    func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
