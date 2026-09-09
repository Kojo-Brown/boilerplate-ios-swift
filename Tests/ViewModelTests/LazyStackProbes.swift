import Foundation
import SwiftUI
@testable import Core
@testable import Features

// MARK: - Labels

/// Labels the lazy-stack probes record under.
///
/// The identity harness records one label per *item*, not per row, so that a
/// count answers "did the row holding item 3 mount again?" rather than "did
/// something at position 2 mount again?" — the difference between those two
/// questions is the whole subject of `LazyStackIdentityTests`.
enum LazyProbeLabel {
    static let lazyRow = "lazy-row"
    static let eagerRow = "eager-row"

    static func stable(_ id: Int) -> String { "stable:\(id)" }
    static func indexed(_ id: Int) -> String { "indexed:\(id)" }
    static func tagged(_ id: Int) -> String { "tagged:\(id)" }
}

// MARK: - Settling

/// Settles `harness` until `condition` holds, or until the budget is spent.
///
/// A single ``RenderHarness/settle(for:)`` is enough when the thing being waited
/// for is a SwiftUI update, because that is what settling flushes. It is not
/// enough here: the first page is fetched by a `.task` the framework starts when
/// the view appears, so the wait is for a task to be scheduled, to run, and for
/// the update it causes to be flushed — three hops, none of which is a fixed
/// duration. Polling in 50 ms steps and stopping at the first frame where the
/// condition holds keeps the common case fast and gives a slow CI runner room,
/// which one long `Task.sleep` cannot do in both directions at once.
///
/// A condition that never holds simply runs out of attempts and returns. It is
/// deliberately not a failure here — the assertion that follows is what reports
/// it, with the counts in hand and a message that says what was actually
/// loaded.
@MainActor
func settleUntil<Root: View>(
    _ harness: RenderHarness<Root>,
    attempts: Int = 40,
    until condition: () -> Bool
) async {
    for _ in 0..<attempts {
        if condition() { return }
        await harness.settle()
    }
}

// MARK: - Realisation harnesses

/// A row that records one evaluation of its own body every time it is built.
///
/// The probe sits in `body` rather than in an initialiser, because what is being
/// counted here is *realisation*: a lazy stack constructs the row values it
/// needs and runs the body of the ones it is actually going to display, and only
/// the second of those is the work laziness exists to avoid.
struct ProbedRow: View {
    let label: String
    let height: CGFloat
    let ledger: BodyEvaluationLedger

    var body: some View {
        HStack {
            BodyEvaluationProbe(label, into: ledger)
            Text(label)
                .font(.footnote)
        }
        .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
    }
}

/// `count` rows inside a `ScrollView` + `LazyVStack`: the container under test.
struct LazyRealisationHarness: View {
    let count: Int
    let rowHeight: CGFloat
    let ledger: BodyEvaluationLedger

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { _ in
                    ProbedRow(label: LazyProbeLabel.lazyRow, height: rowHeight, ledger: ledger)
                }
            }
        }
    }
}

/// The same rows in a plain `VStack`, which is the control.
///
/// Identical in every respect a reader would notice on screen, and it builds
/// every row at mount whether or not the reader ever scrolls to it.
struct EagerRealisationHarness: View {
    let count: Int
    let rowHeight: CGFloat
    let ledger: BodyEvaluationLedger

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { _ in
                    ProbedRow(label: LazyProbeLabel.eagerRow, height: rowHeight, ledger: ledger)
                }
            }
        }
    }
}

// MARK: - Identity harness

/// The rows the identity harness renders, and the two things a test does to
/// them: insert one at the front, and change the value a `.id(...)` is keyed on.
@Observable
@MainActor
final class LazyRowDriver {
    var items: [PagedItem]
    var token = 0

    init(items: [PagedItem]) {
        self.items = items
    }
}

/// The same rows, keyed three ways, side by side under one root.
///
/// * `stable` keys each row on the item's `id`, which is what
///   ``LazyPaginatedStack`` does.
/// * `indexed` keys each row on its position, which is what
///   `ForEach(items.indices, id: \.self)` does.
/// * `tagged` keys each row on the item's id *and* a value that changes, which
///   is what reaching for `.id(...)` to force a refresh does.
///
/// ## Why there is no `ScrollView` here
///
/// A `LazyVStack` is only lazy inside a scrolling container — without one it is
/// handed a definite height and builds every row. That is exactly what this
/// harness wants: identity is being measured, and a row that was never realised
/// records no appearance for reasons that have nothing to do with its id. The
/// three stacks are sized to fit the harness window with room to spare so that
/// every row of all three is mounted.
struct LazyIdentityHarness: View {
    let driver: LazyRowDriver
    let ledger: BodyEvaluationLedger

    var body: some View {
        VStack(spacing: 12) {
            LazyVStack(spacing: 0) {
                ForEach(driver.items) { item in
                    AppearanceCountingRow(label: LazyProbeLabel.stable(item.id), ledger: ledger)
                }
            }

            LazyVStack(spacing: 0) {
                ForEach(driver.items.indices, id: \.self) { index in
                    AppearanceCountingRow(label: LazyProbeLabel.indexed(driver.items[index].id), ledger: ledger)
                }
            }

            LazyVStack(spacing: 0) {
                ForEach(driver.items) { item in
                    AppearanceCountingRow(label: LazyProbeLabel.tagged(item.id), ledger: ledger)
                        .id("\(driver.token)-\(item.id)")
                }
            }
        }
    }
}

// MARK: - Pagination harness

/// ``LazyPaginatedStack`` with a row of a known height, so that a test can
/// decide how much of a page fits in the harness window.
///
/// The height is the independent variable of `LazyStackPrefetchTests`: a page
/// taller than the viewport loads once and waits for the reader, and a page
/// shorter than it triggers its own successor.
struct LazyPaginationHarness: View {
    let paginator: CursorPaginator<PagedItem>
    let rowHeight: CGFloat

    var body: some View {
        LazyPaginatedStack(paginator, spacing: 0) { item in
            Text("Item \(item.id)")
                .font(.footnote)
                .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        }
    }
}
