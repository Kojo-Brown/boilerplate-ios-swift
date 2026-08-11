import Foundation

/// The delay schedule behind `Retry.run`: exponential growth up to a ceiling,
/// with a jitter strategy deciding how much of each delay is randomised.
///
/// ```swift
/// // 100ms, 200ms, 400ms … capped at 30s, each drawn uniformly from its range.
/// var schedule = Backoff().schedule()
/// let firstDelay = schedule.next()
/// ```
///
/// ## Backoff alone does not spread load; it synchronises it
///
/// Exponential backoff is nearly always introduced as the fix for a server
/// buckling under retries, and on its own it is not one. Delays of 1s, 2s, 4s,
/// 8s are *the same delays for every client*, so a thousand callers that failed
/// in the same second retry in the same second, four times over, and the moment
/// the server comes back up is the moment all thousand arrive at once. The
/// clients have not been spread out; they have been put on a shared clock. What
/// backoff buys is a falling total request rate. What it does not buy is any
/// reduction in the *peak*, and the peak is what knocks the service over again.
///
/// Jitter is the part that spreads them, and it is not a refinement to add
/// later — `.none` exists here to be measured against, not to be used.
/// `RetryTests` runs a thousand simulated clients through both and compares how
/// many land in the same instant: with `.none` all thousand do, by construction,
/// because nothing in the schedule differs between them.
///
/// ## The three jitter strategies, and why `.full` is the default
///
/// From Marc Brooker's "Exponential Backoff And Jitter" (AWS Architecture Blog,
/// 2015), which measured all three against a contended store:
///
/// - `.full` — `random(0, exponential)`. The strongest spreading of the three,
///   and the fewest total calls in Brooker's numbers. Its one cost is that an
///   individual retry can land almost immediately, so a client is not
///   *guaranteed* to have backed off at all on any given attempt. That matters
///   to a single client's tail latency and not to the server, which is why it is
///   the default here.
/// - `.equal` — `exponential/2 + random(0, exponential/2)`. Keeps half the delay
///   deterministic, so every retry has backed off by at least half the term.
///   Choose it when a hard floor between attempts matters, at the cost of
///   spreading the herd across half the window.
/// - `.decorrelated` — `random(base, previous × 3)`, growing from the delay
///   actually slept rather than from the attempt number. The window widens
///   fastest and the sequence is not derivable from the attempt count, so two
///   clients that fail in lockstep do not merely start at different points in
///   the same series — they follow different series.
///
/// All three are clamped to `cap`. Uncapped exponential growth is the other
/// half of the same bug: attempt 20 of a `2×` schedule from 100ms is thirteen
/// hours, which is not a retry, it is an abandonment nobody logged.
struct Backoff: Sendable, Equatable {
    /// A source of uniform values in `0...1`.
    ///
    /// Injected rather than reached for so a test can assert the *schedule*
    /// exactly — the arithmetic is a pure function of the attempt number and
    /// this closure, so it needs no clock, no sleeping, and no tolerance.
    /// `Backoff.systemRandom` is the default and is what production uses.
    typealias UnitRandom = @Sendable () -> Double

    /// How much of each delay is randomised.
    enum Jitter: Sendable, Equatable, CaseIterable {
        /// No randomisation: every client on this policy waits the same delay.
        /// Present so the herd it produces can be measured, not to be selected.
        case none
        /// `random(0, exponential)`.
        case full
        /// `exponential/2 + random(0, exponential/2)`.
        case equal
        /// `random(base, previous × 3)`, grown from the last delay slept.
        case decorrelated
    }

    /// The delay before the first retry, before growth and before jitter.
    let base: Duration
    /// What each successive exponential term multiplies the last one by.
    let multiplier: Double
    /// The ceiling on any single delay, applied before jitter.
    let cap: Duration
    /// How much of each delay is randomised.
    let jitter: Jitter

    /// - Parameters:
    ///   - base: The first exponential term. Must be positive.
    ///   - multiplier: Growth per retry. Must be at least 1 — a multiplier below
    ///     1 is a schedule that retries *faster* under sustained failure, which
    ///     is the load pattern backoff exists to prevent.
    ///   - cap: The ceiling on any single delay. Must be at least `base`.
    ///   - jitter: How much of each delay is randomised.
    init(
        base: Duration = .milliseconds(100),
        multiplier: Double = 2,
        cap: Duration = .seconds(30),
        jitter: Jitter = .full
    ) {
        precondition(base > .zero, "base must be positive, got \(base)")
        precondition(multiplier.isFinite, "multiplier must be finite, got \(multiplier)")
        precondition(multiplier >= 1, "multiplier must be at least 1, got \(multiplier)")
        precondition(cap >= base, "cap (\(cap)) must be at least base (\(base))")
        self.base = base
        self.multiplier = multiplier
        self.cap = cap
        self.jitter = jitter
    }

    /// Starts a fresh run of this schedule.
    ///
    /// The returned value is a `struct` carrying its own attempt counter, so two
    /// concurrent retry loops sharing one `Backoff` do not share a position in
    /// the sequence — which they would if the counter lived on the policy.
    func schedule(using random: @escaping UnitRandom = Backoff.systemRandom) -> Schedule {
        Schedule(backoff: self, random: random)
    }

    /// The production randomness source.
    static let systemRandom: UnitRandom = { Double.random(in: 0..<1) }

    /// One retry loop's position in the schedule.
    ///
    /// Deliberately a value type with a `mutating func`: it is advanced from a
    /// single task, between suspension points, and giving it reference semantics
    /// would invite exactly the sharing the doc comment above rules out.
    struct Schedule: Sendable {
        private let backoff: Backoff
        private let random: UnitRandom
        /// How many delays have already been handed out, which is also the
        /// exponent of the next one — the first delay is `base × multiplier⁰`.
        private var retry = 0
        /// The delay last handed out, which `.decorrelated` grows from. Seeded
        /// with `base` so the first draw spans `base ... 3 × base`.
        private var previousSeconds: Double

        fileprivate init(backoff: Backoff, random: @escaping UnitRandom) {
            self.backoff = backoff
            self.random = random
            self.previousSeconds = Backoff.secondsValue(backoff.base)
        }

        /// The delay to wait before the next retry, and advances the schedule.
        ///
        /// Arithmetic runs in `Double` seconds rather than `Duration` because
        /// `Duration` has no multiplication by a `Double` — and because the
        /// growth term has to be clamped to `cap` *before* it becomes a
        /// `Duration`. At attempt 40 of a `2×` schedule the unclamped term
        /// overflows to infinity, and `Duration.seconds(.infinity)` traps.
        mutating func next() -> Duration {
            let baseSeconds = Backoff.secondsValue(backoff.base)
            let capSeconds = Backoff.secondsValue(backoff.cap)
            let growth = pow(backoff.multiplier, Double(retry))
            let exponential = min(capSeconds, baseSeconds * growth)
            retry += 1

            let chosen: Double
            switch backoff.jitter {
            case .none:
                chosen = exponential
            case .full:
                chosen = exponential * unit()
            case .equal:
                let half = exponential / 2
                chosen = half + half * unit()
            case .decorrelated:
                // Grown from the last delay rather than from `retry`, and still
                // capped: `previous × 3` compounds faster than the `2×` term.
                let upper = min(capSeconds, previousSeconds * 3)
                chosen = upper <= baseSeconds
                    ? baseSeconds
                    : baseSeconds + (upper - baseSeconds) * unit()
            }

            // Read back only by `.decorrelated`; written unconditionally so that
            // switching strategy mid-run cannot resume from a stale position.
            previousSeconds = chosen
            return Backoff.duration(seconds: chosen)
        }

        /// One draw from `random`, clamped into `0...1`.
        ///
        /// The clamp is about the injected source, not the system one: a caller
        /// that supplies its own must not be able to turn a delay negative (a
        /// `Duration` in the past, which `Task.sleep` returns from immediately)
        /// or NaN (which traps on conversion). Garbage in gives a valid delay
        /// out rather than a crash in someone else's retry loop.
        private func unit() -> Double {
            let drawn = random()
            guard drawn.isFinite else { return 0 }
            return min(max(drawn, 0), 1)
        }
    }

    /// A `Duration` as a count of seconds.
    ///
    /// `components` is exact — `attoseconds` is an integer count, not a rounding
    /// — so the only loss is `Double`'s 53-bit significand, which is a relative
    /// error around 1e-16. On a 30-second cap that is a few femtoseconds.
    fileprivate static func secondsValue(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }

    /// A count of seconds as a `Duration`, refusing to produce a negative or
    /// non-finite one.
    fileprivate static func duration(seconds value: Double) -> Duration {
        guard value.isFinite, value > 0 else { return .zero }
        return .seconds(value)
    }
}
