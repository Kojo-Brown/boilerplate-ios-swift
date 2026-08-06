import Foundation

/// Asks, synchronously, whether the caller is running on the main thread.
///
/// This exists because `Thread.isMainThread` is imported with
/// `NS_SWIFT_UNAVAILABLE_FROM_ASYNC`, so referring to it *directly* inside an
/// `async` function is a compile error rather than a warning:
///
/// ```
/// error: class property 'isMainThread' is unavailable from asynchronous
/// contexts; Work intended for the main actor should be marked with @MainActor
/// ```
///
/// Foundation is right to refuse. In an async function the thread can change at
/// every suspension point, so "which thread am I on" is a question whose answer
/// expires — and code that branches on it is almost always code that should have
/// been `@MainActor` instead. The advice is for production code, and it is good.
///
/// The tests here want the expiring answer on purpose: measuring *where a hop
/// landed* is the whole point, and there is no way to ask that in terms of
/// isolation, because isolation is the thing being measured. Reading it through
/// a synchronous function is the sanctioned way to do it. Nothing is dodged —
/// a synchronous function body contains no suspension points, so the answer
/// cannot go stale between being read and being returned.
///
/// It doubles as the probe for one of the rules under test. Being `nonisolated`
/// and synchronous, this property runs wherever its caller already is; it never
/// hops, and it never inherits an actor. That is why it can report the caller's
/// thread at all, and why a `nonisolated func` is *not* a way to get off the main
/// actor.
enum CurrentThread {
    /// Whether this call is executing on the main thread.
    ///
    /// Not the same question as "is this the main actor" — the main actor is the
    /// abstraction, the main thread is the implementation currently backing it.
    /// It is the honest tool available: the cooperative pool never schedules
    /// non-main-actor work onto the main thread, so the two answers coincide in
    /// practice, and `MainActor.assertIsolated()` would trap the process rather
    /// than fail a test.
    static var isMain: Bool {
        Thread.isMainThread
    }
}
