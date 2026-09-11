import Foundation
import os

/// A tally of the work a search actually did.
///
/// The counterpart to `BodyEvaluationLedger`, and it exists for the same
/// reason: the claim being made about a hotspot is "this runs once per
/// keystroke rather than four times", and a wall-clock assertion cannot make
/// that claim. A duration is a load meter — green on an idle machine, red on a
/// busy one, and this repository has already deleted one test that asserted on
/// one (see the Phase 9 notes in `SPEC.md`). A count of scans is the same
/// number on a loaded CI runner as on a quiet laptop, and it is the number the
/// fix is actually about.
///
/// What it does *not* claim: that a scan is cheap. Counting says how often the
/// work happens, Instruments says what one of them costs, and
/// `docs/profiling.md` is the walkthrough for the second half.
///
/// Lock-backed rather than `@unchecked Sendable` over bare counters, because a
/// ``SearchIndex`` is `Sendable` precisely so that it can be built off the main
/// actor, and its ledger travels with it.
package final class SearchWorkLedger: Sendable {

    private struct Counts {
        var indexBuilds = 0
        var foldedKeys = 0
        var scans = 0
        var comparisons = 0
        var cacheHits = 0
    }

    private let counts = OSAllocatedUnfairLock(initialState: Counts())

    package init() {}

    /// How many times a corpus was folded into search keys.
    package var indexBuilds: Int { counts.withLock { $0.indexBuilds } }

    /// How many individual keys were folded across every build.
    ///
    /// The cost of building an index is per *key*, not per element: an element
    /// with a title and a subtitle folds twice.
    package var foldedKeys: Int { counts.withLock { $0.foldedKeys } }

    /// How many times the index was walked end to end.
    package var scans: Int { counts.withLock { $0.scans } }

    /// How many key-against-query comparisons those scans performed.
    package var comparisons: Int { counts.withLock { $0.comparisons } }

    /// How many reads were answered from ``MemoizedSearch``'s cache without a
    /// scan.
    package var cacheHits: Int { counts.withLock { $0.cacheHits } }

    package func recordIndexBuild(foldedKeys keys: Int) {
        counts.withLock { current in
            current.indexBuilds += 1
            current.foldedKeys += keys
        }
    }

    package func recordScan(comparisons made: Int) {
        counts.withLock { current in
            current.scans += 1
            current.comparisons += made
        }
    }

    package func recordCacheHit() {
        counts.withLock { $0.cacheHits += 1 }
    }

    /// Drops every count, so a measurement can start from a loaded screen
    /// rather than from an empty one.
    ///
    /// The first scan after a corpus arrives is not redundant — it is the
    /// search. A test that wants to measure what a *read* costs loads the
    /// screen, resets here, and then reads.
    package func reset() {
        counts.withLock { $0 = Counts() }
    }
}
