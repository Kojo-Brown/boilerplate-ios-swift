import Foundation
import Testing
import os
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

// MARK: - Deterministic randomness

/// SplitMix64, so a jittered schedule is reproducible from a seed.
///
/// Jitter is the point of `Backoff`, and a suite that drew from the system
/// generator could only ever assert ranges. Seeding it makes the *distribution*
/// assertable too — `BackoffTests` compares two herds whose only difference is
/// the jitter strategy, and gets the same numbers on every run and every
/// machine.
struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// The next uniform value in `0..<1`.
    ///
    /// The top 53 bits are the ones taken, because that is exactly `Double`'s
    /// significand: shifting down and scaling by `2⁻⁵³` gives every
    /// representable value in the interval equal probability, where dividing by
    /// `UInt64.max` would not.
    mutating func nextUnit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        mixed ^= mixed >> 31
        return Double(mixed >> 11) * 0x1p-53
    }
}

/// A reproducible `Backoff.UnitRandom`.
///
/// The generator is `mutating` and `UnitRandom` is a `@Sendable` closure that
/// captures it, so the state lives *inside* the lock rather than beside it —
/// the discipline `LockedCounter` uses, and what lets this be `Sendable` by the
/// compiler's reckoning rather than by assertion.
final class SeededRandom: Sendable {
    private let generator: OSAllocatedUnfairLock<SplitMix64>

    init(seed: UInt64) {
        generator = OSAllocatedUnfairLock(initialState: SplitMix64(seed: seed))
    }

    var draw: Backoff.UnitRandom {
        { [generator] in generator.withLock { $0.nextUnit() } }
    }
}

// MARK: - Test doubles

/// Records the delays a retry loop asked for, and never spends them.
///
/// This is what makes "no sleep after the last attempt" an observation rather
/// than a reading of the source: the recorded delays are the assertion, and the
/// suite runs in milliseconds because none of them is real.
final class SleepLog: Sendable {
    private let entries = OSAllocatedUnfairLock<[Duration]>(initialState: [])

    var delays: [Duration] { entries.withLock { $0 } }

    var sleep: Retry.Sleep {
        { [entries] duration in entries.withLock { $0.append(duration) } }
    }
}

/// The attempt numbers the operation was handed, in order.
actor AttemptRecorder {
    private(set) var recorded: [Int] = []

    func record(_ attempt: Int) {
        recorded.append(attempt)
    }
}

// MARK: - Duration helpers

/// A `Duration` as whole milliseconds, rounded.
///
/// The schedule's arithmetic round-trips through `Double` seconds, so
/// `Duration.seconds(0.1)` differs from `Duration.milliseconds(100)` by a few
/// attoseconds and the two are not `==`. Comparing at millisecond resolution is
/// the tolerance, and it is twelve orders of magnitude coarser than the error.
func milliseconds(_ duration: Duration) -> Int {
    let parts = duration.components
    let whole = Double(parts.seconds) * 1000 + Double(parts.attoseconds) * 1e-15
    return Int(whole.rounded())
}
