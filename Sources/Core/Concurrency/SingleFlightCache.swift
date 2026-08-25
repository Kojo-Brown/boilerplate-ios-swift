import Foundation

/// An actor-isolated cache that runs at most one load per key, however many
/// callers ask for that key at once.
///
/// This is the shape most shared mutable state in an app wants: state that
/// several tasks read and write concurrently, plus an expensive way to produce a
/// missing entry that must not run more than once. Making it an `actor` is what
/// removes the lock; getting the *reentrancy* right is what removes the
/// duplicate work. Those are two different problems, and only the first one is
/// solved by the `actor` keyword.
///
/// Usage:
/// ```swift
/// let avatars = SingleFlightCache<URL, Data> { url in
///     try await URLSession.shared.data(from: url).0
/// }
///
/// // Fifty views asking at once produce one request.
/// let data = try await avatars.value(for: url)
///
/// // A push telling us the resource changed:
/// await avatars.invalidate(url)
/// ```
///
/// ## The reentrancy pitfall
///
/// An actor serialises access to its state, so it is tempting to read it as a
/// mutex around the whole method body. It is not. An actor guarantees mutual
/// exclusion only *between* suspension points: at every `await` inside an
/// isolated method the actor is released, and another call can run to
/// completion before the first one resumes. That is reentrancy, and it is
/// deliberate — it is what stops an actor awaiting the network from blocking
/// every other caller — but it means an `await` is a hole in whatever invariant
/// the method is maintaining across it.
///
/// The naive cache is the canonical way to fall in:
///
/// ```swift
/// actor NaiveCache {
///     private var cached: [Key: Value] = [:]
///
///     func value(for key: Key) async throws -> Value {
///         if let hit = cached[key] { return hit }   // 1. check
///         let value = try await load(key)           // 2. suspend — actor released
///         cached[key] = value                       // 3. act
///         return value
///     }
/// }
/// ```
///
/// Nothing there is a data race; the compiler is satisfied, and it is right to
/// be. It is still wrong. Five callers arriving on a cold key all get past step
/// 1 before any of them reaches step 3, so the load runs five times — which
/// `SingleFlightCacheTests` demonstrates on that exact actor rather than
/// asserting it in prose. A check-then-act sequence split by an `await` is not
/// atomic, and state read before a suspension may be stale after it.
///
/// Two rules come out of that, and this type is built from both.
///
/// **Publish the in-flight work before the first `await`.** `value(for:)` finds
/// no entry, creates the `Task`, and stores it — all without suspending, so no
/// other call can interleave in the middle. A second caller therefore either
/// arrives before that write and starts the load, or arrives after it and finds
/// a task to await. There is no third possibility, which is exactly the
/// guarantee steps 1-to-3 above lacked.
///
/// **Re-read shared state after an `await`; never write through it blindly.**
/// When `task.value` returns, `entries[key]` holds whatever it holds *now*, not
/// what it held when the load started — `invalidate(_:)` may have run in
/// between. Storing the result unconditionally would resurrect an entry a
/// caller had explicitly dropped, and resurrect it with the stale value it was
/// dropped for. So the completion path re-reads the slot and writes only if it
/// still holds the same task, compared by identity.
///
/// Errors are not cached: a failed load leaves the key empty so the next caller
/// retries. Only success is memoised.
package actor SingleFlightCache<Key: Hashable & Sendable, Value: Sendable> {
    /// Produces the value for a key. Runs at most once per successful cache fill.
    package typealias Load = @Sendable (Key) async throws -> Value

    private enum Entry {
        case inFlight(Task<Value, Error>)
        case ready(Value)
    }

    private let load: Load
    private var entries: [Key: Entry] = [:]

    /// - Parameter load: The expensive operation this cache coalesces. It is
    ///   `@Sendable` because it runs outside this actor's isolation, so it must
    ///   not close over mutable state that anything else touches.
    package init(load: @escaping Load) {
        self.load = load
    }

    // MARK: - Reading

    /// Returns the value for `key`, loading it if no load has produced one yet.
    ///
    /// Concurrent callers for the same key share a single load and all receive
    /// the same value — or the same error, which is not cached.
    package func value(for key: Key) async throws -> Value {
        switch entries[key] {
        case .some(.ready(let value)):
            return value
        case .some(.inFlight(let task)):
            return try await task.value
        case .none:
            // Creating the task and recording it are both synchronous, so this
            // runs in the same uninterrupted stretch of actor execution as the
            // lookup above. That is what makes the load single-flight: there is
            // no suspension point between finding the key empty and claiming it.
            let task = Task<Value, Error> { [load = self.load] in
                try await load(key)
            }
            entries[key] = .inFlight(task)
            return try await awaitResult(of: task, for: key)
        }
    }

    /// The cached value for `key`, if a load has already completed for it.
    ///
    /// Deliberately does not wait on an in-flight load: it reports what the
    /// cache holds, so it is safe on a path that must not trigger work.
    package func cachedValue(for key: Key) -> Value? {
        if case .some(.ready(let value)) = entries[key] {
            return value
        }
        return nil
    }

    // MARK: - Invalidation

    /// Drops any value cached for `key` and cancels a load still in flight for it.
    ///
    /// A load already running does not get to fill the cache afterwards — when
    /// it finishes it finds its claim on the key gone and leaves it gone.
    package func invalidate(_ key: Key) {
        if case .some(.inFlight(let task)) = entries[key] {
            task.cancel()
        }
        entries[key] = nil
    }

    /// Empties the cache and cancels every load still in flight.
    package func invalidateAll() {
        for entry in entries.values {
            if case .inFlight(let task) = entry {
                task.cancel()
            }
        }
        entries.removeAll()
    }

    // MARK: - Completion

    /// Awaits the shared load for `key` and records its outcome.
    private func awaitResult(of task: Task<Value, Error>, for key: Key) async throws -> Value {
        do {
            let value = try await task.value
            publish(.ready(value), for: key, ifStillClaiming: task)
            return value
        } catch {
            publish(nil, for: key, ifStillClaiming: task)
            throw error
        }
    }

    /// Writes `entry` into `key`'s slot, but only if that slot still holds `task`.
    ///
    /// This guard is what makes a post-`await` write safe. Between starting the
    /// load and returning here, another call may have invalidated the key or
    /// started a newer load for it; either way this task's result is no longer
    /// the one that belongs there. Passing `nil` clears the slot.
    private func publish(_ entry: Entry?, for key: Key, ifStillClaiming task: Task<Value, Error>) {
        guard case .some(.inFlight(let current)) = entries[key], current == task else {
            return
        }
        entries[key] = entry
    }
}

// MARK: - Freshness

extension SingleFlightCache {

    /// Returns the value for `key`, first dropping the cached one if `isFresh`
    /// rejects it.
    ///
    /// Expiry is deliberately not a property of this cache. A time-to-live is
    /// only one way for a cached value to go stale — an ETag, a version counter
    /// and a push telling the app the resource changed are three others — and
    /// each of them is knowledge the caller has and this type does not. What
    /// this type has is the thing the caller cannot safely write itself: the
    /// check and the drop happen in one uninterrupted stretch of actor
    /// execution, so no other call can fill the slot between reading the
    /// staleness and acting on it. That is the same check-then-act atomicity
    /// `value(for:)` exists to provide, applied one level up.
    ///
    /// An entry still in flight is not offered to `isFresh`: `cachedValue(for:)`
    /// reports only completed loads, so a caller arriving mid-load joins it and
    /// receives a value that was, by definition, produced just now.
    ///
    /// - Parameters:
    ///   - key: The entry to read.
    ///   - isFresh: Whether the currently cached value may still answer. Called
    ///     at most once, synchronously, with the value in the cache.
    /// - Returns: The cached value if it was accepted, otherwise a newly loaded
    ///   one.
    package func freshValue(for key: Key, isFresh: @Sendable (Value) -> Bool) async throws -> Value {
        if let cached = cachedValue(for: key), !isFresh(cached) {
            invalidate(key)
        }
        return try await value(for: key)
    }
}
