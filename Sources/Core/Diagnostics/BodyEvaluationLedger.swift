import SwiftUI

// MARK: - Ledger

/// A tally of how many times each labelled piece of a view tree has been built.
///
/// SwiftUI gives no supported way to ask "how often did this body run" —
/// `Self._printChanges()` is underscored, prints rather than returns, and says
/// *why* a view was invalidated rather than how many times it was. So the count
/// has to be kept by the tree itself: a ``BodyEvaluationProbe`` placed inside
/// the region under test records one evaluation into a ledger every time it is
/// constructed, and a test or a preview reads the totals back out.
///
/// ```swift
/// let ledger = BodyEvaluationLedger()
///
/// VStack {
///     BodyEvaluationProbe("row", into: ledger)
///     Text(item.title)
/// }
/// ```
///
/// ## Why this is not `@Observable`
///
/// It is written to *from inside a body*. An `@Observable` ledger read by any
/// view in the same tree would invalidate that view on every recording, which
/// re-runs the body, which records again: the instrument would create exactly
/// the redundant evaluations it exists to count, and would not terminate.
/// Nothing here is published, and readers are tests and previews that look at
/// the totals after the fact rather than rendering them.
///
/// ## Why `@MainActor` and not a lock
///
/// A body only ever runs on the main actor, so main-actor isolation is the
/// cheapest correct answer and needs no `@unchecked Sendable` escape hatch. The
/// alternative — a lock around a dictionary — would buy the ability to record
/// from a background thread, which no view body can do anyway.
@MainActor
package final class BodyEvaluationLedger {

    private var counts: [String: Int] = [:]

    package init() {}

    /// Records one evaluation against `label`.
    package func record(_ label: String) {
        counts[label, default: 0] += 1
    }

    /// How many evaluations have been recorded against `label`.
    ///
    /// A label that has never been recorded reads as `0` rather than trapping,
    /// so "this body never ran" is a value a test can assert on.
    package func count(of label: String) -> Int {
        counts[label] ?? 0
    }

    /// Every label recorded so far, with its count.
    package var snapshot: [String: Int] {
        counts
    }

    /// The number of evaluations recorded across every label.
    package var total: Int {
        counts.values.reduce(0, +)
    }

    /// Drops every count, so a measurement can start from a rendered tree
    /// rather than from an empty one.
    ///
    /// The first render of any view is not redundant — it is the render. A test
    /// that wants to measure what an *update* costs mounts the tree, resets
    /// here, and then changes the state under test.
    package func reset() {
        counts.removeAll(keepingCapacity: true)
    }
}

// MARK: - Probe

/// A zero-size view that records one evaluation into a ``BodyEvaluationLedger``
/// each time it is built.
///
/// The recording happens in `init`, not in `body`, and the difference is the
/// whole point. Constructing this value *is* the enclosing body running: the
/// `ViewBuilder` closure it sits in has been called. Recording from its own
/// `body` would count something else — SwiftUI is free to skip the body of a
/// view it considers unchanged, and this one has no stored properties, so it
/// would be considered unchanged every time and the counter would sit at 1
/// while the tree around it was rebuilt on every frame.
///
/// Where the probe sits therefore decides what is being measured:
///
/// * directly inside a parent's `body` — counts that parent's evaluations;
/// * inside the content closure of a `Memoized` (in `Features`) — counts the
///   evaluations the memoisation did *not* skip.
package struct BodyEvaluationProbe: View {

    /// Records an evaluation of `label` if a ledger was supplied.
    ///
    /// The ledger is optional so a probe can be left in a view that is being
    /// investigated and cost a `nil` check when nobody is measuring.
    ///
    /// The isolation is spelled out rather than inherited from `View`'s own
    /// `@MainActor` annotation, because this initialiser touches main-actor
    /// state and should say so at the point a reader is deciding whether a
    /// probe is safe to drop into a given tree.
    @MainActor
    package init(_ label: String, into ledger: BodyEvaluationLedger?) {
        ledger?.record(label)
    }

    package var body: some View {
        EmptyView()
    }
}
