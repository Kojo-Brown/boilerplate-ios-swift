import Foundation
import Testing
@testable import BoilerplateiOSSwift

// MARK: - Test helpers

/// Counts the loads a cache actually performs.
///
/// The loader closure is `@Sendable` and runs outside the cache's isolation, so
/// it cannot mutate a captured `var`. An actor is the natural counter here, and
/// it keeps the test using the same tool it is testing.
private actor LoadRecorder {
    private var keys: [String] = []

    var count: Int { keys.count }

    /// Records one load of `key` and returns the running total.
    @discardableResult
    func record(_ key: String) -> Int {
        keys.append(key)
        return keys.count
    }

    /// How many loads have run for `key` specifically.
    func loads(for key: String) -> Int {
        keys.filter { $0 == key }.count
    }
}

private enum CacheTestError: Error, Equatable {
    case transient
}

/// The mistake `SingleFlightCache` exists to avoid, kept runnable so the pitfall
/// is demonstrated rather than asserted.
///
/// `cached[key]` is read, the load is awaited, and the result is written back —
/// the check-then-act sequence split by a suspension point that actor
/// reentrancy makes non-atomic. Nothing here is a data race and it compiles
/// clean under Swift 6; it simply does the work once per concurrent caller.
private actor NaiveCache {
    private let load: @Sendable (String) async throws -> Int
    private var cached: [String: Int] = [:]

    init(load: @escaping @Sendable (String) async throws -> Int) {
        self.load = load
    }

    func value(for key: String) async throws -> Int {
        if let hit = cached[key] {
            return hit
        }
        let value = try await load(key)
        cached[key] = value
        return value
    }
}

// MARK: - Tests

@Suite("SingleFlightCache")
struct SingleFlightCacheTests {

    // MARK: Caching

    @Test("a completed load is served from the cache on the next call")
    func secondCallIsServedFromCache() async throws {
        let recorder = LoadRecorder()
        let cache = SingleFlightCache<String, Int> { key in
            await recorder.record(key)
            return key.count
        }

        let first = try await cache.value(for: "alpha")
        let second = try await cache.value(for: "alpha")

        #expect(first == 5)
        #expect(second == 5)
        let count = await recorder.count
        #expect(count == 1)
    }

    @Test("distinct keys are loaded independently")
    func distinctKeysLoadIndependently() async throws {
        let recorder = LoadRecorder()
        let cache = SingleFlightCache<String, Int> { key in
            await recorder.record(key)
            return key.count
        }

        let alpha = try await cache.value(for: "alpha")
        let beta = try await cache.value(for: "beta")

        #expect(alpha == 5)
        #expect(beta == 4)
        let alphaLoads = await recorder.loads(for: "alpha")
        let betaLoads = await recorder.loads(for: "beta")
        #expect(alphaLoads == 1)
        #expect(betaLoads == 1)
    }

    @Test("cachedValue reports nothing until a load has completed")
    func cachedValueReflectsCompletedLoadsOnly() async throws {
        let cache = SingleFlightCache<String, Int> { key in key.count }

        let beforeLoad = await cache.cachedValue(for: "alpha")
        #expect(beforeLoad == nil)

        _ = try await cache.value(for: "alpha")

        let afterLoad = await cache.cachedValue(for: "alpha")
        #expect(afterLoad == 5)
    }

    // MARK: Coalescing — the reason the type exists

    @Test("ten concurrent callers for one key share a single load")
    func concurrentCallersShareOneLoad() async throws {
        let recorder = LoadRecorder()
        let cache = SingleFlightCache<String, Int> { key in
            await recorder.record(key)
            try await Task.sleep(for: .milliseconds(80))
            return key.count
        }

        let values = try await withThrowingTaskGroup(
            of: Int.self,
            returning: [Int].self
        ) { group in
            for _ in 0..<10 {
                group.addTask { try await cache.value(for: "alpha") }
            }
            var collected: [Int] = []
            for try await value in group {
                collected.append(value)
            }
            return collected
        }

        #expect(values.count == 10)
        #expect(Set(values) == [5])
        let count = await recorder.count
        #expect(count == 1)
    }

    @Test("the naive check-then-await-then-act cache really does duplicate work")
    func naiveCacheDuplicatesConcurrentLoads() async throws {
        let recorder = LoadRecorder()
        let cache = NaiveCache { key in
            await recorder.record(key)
            try await Task.sleep(for: .milliseconds(80))
            return key.count
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = try await cache.value(for: "alpha") }
            }
            try await group.waitForAll()
        }

        // Five callers, five loads: the actor serialised access to `cached` and
        // still let every one of them past the emptiness check, because the
        // `await` in between released the actor.
        let count = await recorder.count
        #expect(count == 5)
    }

    // MARK: Failure

    @Test("a failed load is not cached and the next caller retries")
    func failedLoadIsNotCached() async throws {
        let recorder = LoadRecorder()
        let cache = SingleFlightCache<String, Int> { key in
            let attempt = await recorder.record(key)
            if attempt == 1 {
                throw CacheTestError.transient
            }
            return key.count
        }

        var caught: (any Error)?
        do {
            _ = try await cache.value(for: "alpha")
        } catch {
            caught = error
        }
        #expect(caught as? CacheTestError == .transient)

        let cachedAfterFailure = await cache.cachedValue(for: "alpha")
        #expect(cachedAfterFailure == nil)

        let retried = try await cache.value(for: "alpha")
        #expect(retried == 5)
        let count = await recorder.count
        #expect(count == 2)
    }

    @Test("concurrent callers all see the error from the shared failed load")
    func concurrentCallersShareOneFailure() async throws {
        let recorder = LoadRecorder()
        let cache = SingleFlightCache<String, Int> { key in
            await recorder.record(key)
            try await Task.sleep(for: .milliseconds(80))
            throw CacheTestError.transient
        }

        let failures = await withTaskGroup(
            of: Bool.self,
            returning: [Bool].self
        ) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        _ = try await cache.value(for: "alpha")
                        return false
                    } catch {
                        return (error as? CacheTestError) == .transient
                    }
                }
            }
            var collected: [Bool] = []
            for await didFail in group {
                collected.append(didFail)
            }
            return collected
        }

        #expect(failures.count == 5)
        #expect(!failures.contains(false))
        let count = await recorder.count
        #expect(count == 1)
    }

    // MARK: Invalidation

    @Test("invalidate drops the cached value so the next call reloads")
    func invalidateForcesReload() async throws {
        let recorder = LoadRecorder()
        let cache = SingleFlightCache<String, Int> { key in
            await recorder.record(key)
            return key.count
        }

        _ = try await cache.value(for: "alpha")
        await cache.invalidate("alpha")

        let cachedAfterInvalidate = await cache.cachedValue(for: "alpha")
        #expect(cachedAfterInvalidate == nil)

        _ = try await cache.value(for: "alpha")
        let count = await recorder.count
        #expect(count == 2)
    }

    @Test("invalidateAll empties every key")
    func invalidateAllEmptiesEveryKey() async throws {
        let recorder = LoadRecorder()
        let cache = SingleFlightCache<String, Int> { key in
            await recorder.record(key)
            return key.count
        }

        _ = try await cache.value(for: "alpha")
        _ = try await cache.value(for: "beta")
        await cache.invalidateAll()

        let cachedAlpha = await cache.cachedValue(for: "alpha")
        let cachedBeta = await cache.cachedValue(for: "beta")
        #expect(cachedAlpha == nil)
        #expect(cachedBeta == nil)
    }

    /// The post-`await` half of the reentrancy rule: a load that was in flight
    /// when its key was invalidated must not fill the cache when it finishes.
    /// Writing the result back unconditionally would resurrect the entry the
    /// caller had just dropped — with the stale value it dropped it for.
    ///
    /// The ordering this needs — invalidate strictly after the load registers
    /// and strictly before it returns — is driven by a `TaskGate` rather than
    /// inferred from sleeps, the same way `TimeoutTests` and
    /// `CancellableContinuationTests` drive theirs.
    ///
    /// It used to be a 40ms sleep against a 200ms load, and that margin is what
    /// `AsyncPoll`'s own doc comment warns about: on a loaded runner the two
    /// sleeps invert, the load completes and publishes *before* `invalidate`
    /// runs, and the caller gets a value where the test demanded a
    /// `CancellationError`. That is what happened on run #47 of this branch —
    /// the test took 9.7 seconds for ~240ms of intended work and failed on the
    /// `caught` assertion alone, while the other two still passed, which is the
    /// signature of the load having finished early rather than of a defect in
    /// `SingleFlightCache`. No assertion below is changed; only the handshake
    /// is, so the mid-flight window is now guaranteed on every run instead of
    /// raced for.
    @Test("a load invalidated mid-flight does not fill the cache afterwards")
    func invalidateDuringLoadDoesNotPublishResult() async throws {
        let recorder = LoadRecorder()
        let gate = TaskGate()
        let cache = SingleFlightCache<String, Int> { key in
            await recorder.record(key)
            // Park until the test has invalidated the key, ignoring the
            // cancellation here so that it is observed at the check below —
            // where this load would have published — rather than from inside
            // the parking spot.
            await gate.waitForOpeningIgnoringCancellation(at: 0)
            try Task.checkCancellation()
            return key.count
        }

        let caller = Task { try await cache.value(for: "alpha") }

        try await AsyncPoll.until("the load never reached the gate") {
            await gate.arrivedCount == 1
        }
        await cache.invalidate("alpha")
        await gate.open(0)

        var caught: (any Error)?
        do {
            _ = try await caller.value
        } catch {
            caught = error
        }
        #expect((caught as? CancellationError) != nil)

        let cachedAfterInvalidate = await cache.cachedValue(for: "alpha")
        #expect(cachedAfterInvalidate == nil)
        let count = await recorder.count
        #expect(count == 1)
    }
}
