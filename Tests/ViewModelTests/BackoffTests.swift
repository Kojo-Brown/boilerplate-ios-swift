import Foundation
import Testing
@testable import BoilerplateiOSSwift
@testable import Core
@testable import Features
@testable import Networking

/// Growth, the ceiling, what each jitter strategy is allowed to produce — and
/// the herd that `.none` produces and `.full` does not.
///
/// Every test here is pure arithmetic. The schedule is a function of the attempt
/// number and the random source, so nothing in this suite sleeps, nothing needs
/// a tolerance for a loaded runner, and a thousand simulated clients cost four
/// thousand additions.
@Suite("Backoff schedule")
struct BackoffTests {

    // MARK: Growth and the ceiling

    @Test("without jitter the term doubles and then stops at the cap")
    func exponentialGrowthStopsAtTheCap() {
        var schedule = Backoff(
            base: .milliseconds(100),
            multiplier: 2,
            cap: .seconds(1),
            jitter: .none
        ).schedule(using: { 0 })

        let delays = (0..<6).map { _ in schedule.next() }

        #expect(delays.map(milliseconds) == [100, 200, 400, 800, 1000, 1000])
    }

    @Test("an exponent large enough to overflow still yields the cap")
    func runawayGrowthIsClampedRatherThanTrapping() {
        var schedule = Backoff(
            base: .seconds(1),
            multiplier: 10,
            cap: .seconds(30),
            jitter: .none
        ).schedule(using: { 0 })

        // Attempt 400 of a 10× schedule is 10⁴⁰⁰, which is `Double.infinity`.
        // Clamping to the cap before the conversion is what keeps this from
        // trapping inside `Duration.seconds(_:)` rather than merely returning
        // an absurd delay.
        let delays = (0..<400).map { _ in milliseconds(schedule.next()) }

        #expect(Array(delays.prefix(3)) == [1_000, 10_000, 30_000])
        #expect(delays.dropFirst(2).allSatisfy { $0 == 30_000 })
    }

    @Test("two schedules from one policy do not share a position")
    func schedulesAreIndependent() {
        let backoff = Backoff(base: .milliseconds(100), multiplier: 2, cap: .seconds(30), jitter: .none)

        var first = backoff.schedule(using: { 0 })
        _ = first.next()
        _ = first.next()
        var second = backoff.schedule(using: { 0 })

        // A counter living on the policy rather than on the schedule would put
        // an unrelated caller's first retry at 400ms instead of 100ms.
        #expect(milliseconds(second.next()) == 100)
        #expect(milliseconds(first.next()) == 400)
    }

    // MARK: The strategies

    @Test("full jitter spans zero to the whole term")
    func fullJitterCoversTheWholeTerm() {
        let backoff = Backoff(base: .milliseconds(100), multiplier: 2, cap: .seconds(30), jitter: .full)

        var lowest = backoff.schedule(using: { 0 })
        var highest = backoff.schedule(using: { 1 })

        #expect((0..<4).map { _ in milliseconds(lowest.next()) } == [0, 0, 0, 0])
        #expect((0..<4).map { _ in milliseconds(highest.next()) } == [100, 200, 400, 800])
    }

    @Test("equal jitter keeps half of every term deterministic")
    func equalJitterHalvesTheWindow() {
        let backoff = Backoff(base: .milliseconds(100), multiplier: 2, cap: .seconds(30), jitter: .equal)

        var lowest = backoff.schedule(using: { 0 })
        var highest = backoff.schedule(using: { 1 })

        // The floor is the guarantee `.full` does not make: every attempt has
        // backed off by at least half its term before it runs.
        #expect((0..<4).map { _ in milliseconds(lowest.next()) } == [50, 100, 200, 400])
        #expect((0..<4).map { _ in milliseconds(highest.next()) } == [100, 200, 400, 800])
    }

    @Test("decorrelated jitter grows from the delay it last slept")
    func decorrelatedJitterGrowsFromThePreviousDelay() {
        let backoff = Backoff(
            base: .milliseconds(100),
            multiplier: 2,
            cap: .seconds(30),
            jitter: .decorrelated
        )

        // Each draw spans `base ... previous × 3`, so taking the top of every
        // window triples — a wider window than the 2× term, which is the point.
        var highest = backoff.schedule(using: { 1 })
        #expect((0..<4).map { _ in milliseconds(highest.next()) } == [300, 900, 2700, 8100])

        // …and taking the bottom of every window never falls below `base`,
        // which is what stops the sequence collapsing towards zero.
        var lowest = backoff.schedule(using: { 0 })
        #expect((0..<4).map { _ in milliseconds(lowest.next()) } == [100, 100, 100, 100])
    }

    @Test("every strategy stays inside zero and the cap")
    func everyStrategyRespectsTheCap() {
        let random = SeededRandom(seed: 20_260_811)

        for jitter in Backoff.Jitter.allCases {
            var schedule = Backoff(
                base: .milliseconds(50),
                multiplier: 3,
                cap: .seconds(5),
                jitter: jitter
            ).schedule(using: random.draw)
            let delays = (0..<200).map { _ in schedule.next() }

            #expect(delays.allSatisfy { $0 >= .zero })
            #expect(delays.allSatisfy { $0 <= .seconds(5) })
        }
    }

    @Test("an out-of-range random source cannot produce a negative or infinite delay")
    func aGarbageRandomSourceIsClamped() {
        let backoff = Backoff(base: .milliseconds(100), multiplier: 2, cap: .seconds(30), jitter: .full)

        var negative = backoff.schedule(using: { -5 })
        var oversized = backoff.schedule(using: { 100 })
        var notANumber = backoff.schedule(using: { .nan })

        #expect(milliseconds(negative.next()) == 0)
        #expect(milliseconds(oversized.next()) == 100)
        #expect(milliseconds(notANumber.next()) == 0)
    }

    // MARK: The herd

    @Test("backoff without jitter synchronises the herd it is credited with spreading")
    func jitterIsWhatSpreadsTheHerd() {
        let herdSize = 1_000
        let rounds = 4
        let bucket = Duration.milliseconds(10)

        let synchronised = peakArrivals(
            retryInstants(clients: herdSize, rounds: rounds, jitter: .none),
            bucket: bucket
        )
        let spread = peakArrivals(
            retryInstants(clients: herdSize, rounds: rounds, jitter: .full),
            bucket: bucket
        )

        // Nothing in a `.none` schedule differs between clients, so all thousand
        // land on the recovering server in the same 10ms — four times over. The
        // request *rate* fell; the peak did not move at all, and the peak is
        // what knocks the service back over.
        #expect(synchronised == herdSize)

        // The same thousand clients and the same terms, one strategy apart. The
        // margin is wide because the number it bounds is around a hundred: the
        // first round alone spreads a thousand clients over ten buckets.
        #expect(spread < herdSize / 5)
    }

    /// When a herd of clients that all failed at the same instant retry.
    private func retryInstants(clients: Int, rounds: Int, jitter: Backoff.Jitter) -> [Duration] {
        let backoff = Backoff(base: .milliseconds(100), multiplier: 2, cap: .seconds(30), jitter: jitter)
        var instants: [Duration] = []

        for client in 0..<clients {
            let random = SeededRandom(seed: 1 &+ UInt64(client))
            var schedule = backoff.schedule(using: random.draw)
            var elapsed = Duration.zero
            for _ in 0..<rounds {
                elapsed += schedule.next()
                instants.append(elapsed)
            }
        }

        return instants
    }

    /// The most retries landing in any single bucket — the number a struggling
    /// server actually experiences.
    private func peakArrivals(_ instants: [Duration], bucket: Duration) -> Int {
        let width = milliseconds(bucket)
        var counts: [Int: Int] = [:]
        for instant in instants {
            counts[milliseconds(instant) / width, default: 0] += 1
        }
        return counts.values.max() ?? 0
    }
}
