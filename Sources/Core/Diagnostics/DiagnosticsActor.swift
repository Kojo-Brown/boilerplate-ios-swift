import Dispatch

/// The isolation domain for the app's diagnostics: one serial background
/// context, shared by every type that participates in journalling.
///
/// ```swift
/// @DiagnosticsActor
/// final class RetryPolicy {
///     func note(_ failure: APIError) {
///         // No await: the journal is in this domain too.
///         DiagnosticJournal.shared.record(.network, "retrying after \(failure)")
///     }
/// }
/// ```
///
/// ## Why a global actor rather than an actor
///
/// A plain `actor` gives *one instance* its own isolation domain. That is the
/// right default, and most of this package uses it — `TokenStore` protects token
/// state and nothing else needs to be inside with it.
///
/// It stops being the right default when several types have to see each other's
/// state consistently. Written as separate actors, `DiagnosticJournal` and
/// `DiagnosticBudget` would sit in two domains, so every consultation of the
/// budget would be an `await`: a suspension point in the middle of admitting a
/// record, during which another caller can be admitted against a count that the
/// first caller has already decided to change. The check-then-act split by a
/// suspension is the same non-atomicity `SingleFlightCache` exists to close, and
/// it would be reintroduced here by nothing more than a choice of isolation.
///
/// A global actor is the tool for that: it names one domain that any number of
/// declarations can join, and members of the same domain reach each other
/// *synchronously*. `DiagnosticJournal.record` therefore consults the budget
/// with a plain call, and no state can move underneath it, because there is no
/// suspension point for anything else to run in.
///
/// The cost is real and worth stating: a global actor is global state. Every
/// type annotated `@DiagnosticsActor` shares one queue, so a slow write in one
/// of them delays all of them, and there is no way to get two independent
/// diagnostics domains for, say, a test running in parallel with another test.
/// That is why the journal's initialiser takes its sink and budget rather than
/// reaching for a singleton: the *domain* is global, but the objects in it need
/// not be, and tests build their own.
///
/// ## Why it takes a custom executor
///
/// Because this domain blocks. Its terminal operation is a write to a file
/// descriptor, and the cooperative pool is explicitly not for work that blocks —
/// it has one thread per core and no reserve, so a blocked job there stalls
/// unrelated tasks across the whole process. `SerialDispatchExecutor` gives the
/// domain a thread of its own that it is allowed to block, at a QoS that says
/// this work is never urgent no matter who asked for it. See that type for the
/// rest of the reasoning.
@globalActor
actor DiagnosticsActor {
    /// The single instance whose isolation `@DiagnosticsActor` refers to.
    static let shared = DiagnosticsActor()

    /// The queue-backed executor this domain runs on.
    ///
    /// Held as a stored `let` so it outlives every job scheduled on it —
    /// `UnownedSerialExecutor` does not retain, so something has to.
    ///
    /// `nonisolated` because the actor genuinely does not protect it, and
    /// saying so is not optional here. The runtime reads it through
    /// `unownedExecutor` to schedule work *onto* this actor, which is by
    /// definition from outside the actor's isolation — an executor you had to
    /// be isolated to reach would be unreachable, since reaching it is how you
    /// become isolated. Nothing is given up: the value is an immutable
    /// reference to a `Sendable` type, so there is no state here for isolation
    /// to have been guarding.
    nonisolated let executor = SerialDispatchExecutor(
        label: "com.boilerplate.iosswift.diagnostics",
        qos: .utility
    )

    /// Installs the custom executor. Without this override the actor would use
    /// the default one and every word above would be aspirational.
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    private init() {}
}
