import Core
import SwiftUI

// MARK: - Memoized

/// Content that is only rebuilt when the value it is derived from changes.
///
/// ```swift
/// Memoized(item) { item in
///     ExpensiveRow(item: item)
/// }
/// ```
///
/// ## What this is for
///
/// A SwiftUI body runs whenever *anything* it reads changes. A screen that
/// reads one frequently-changing value — a search field, a scroll offset, a
/// loading flag driving a toolbar spinner — re-runs its whole body on every
/// change of it, and everything built inline in that body is rebuilt with it,
/// including the rows that did not change.
///
/// SwiftUI's own defence is to compare the rebuilt view values against the old
/// ones and skip the subtrees that came back equal, but that comparison is only
/// dependable when the view is `Equatable`. For everything else the framework
/// falls back to comparing the view's memory, which cannot see through the
/// reference-counted storage behind a `String`, an array, or a captured
/// closure — the comparison fails, and the subtree is rebuilt.
///
/// So there are two ways to make the skip deterministic:
///
/// 1. Give the subtree its own `Equatable` view type and apply `.equatable()`.
///    That is what `HomeItemRow` and `HomeItemCard` do, and it is the better
///    answer whenever the subtree is a named view already.
/// 2. Wrap it here. This exists for the case where the content is written
///    inline and giving it a type would be ceremony — and for the case where
///    what the content should be compared on is *narrower* than everything it
///    reads.
///
/// ## How it skips
///
/// `Memoized`'s own body is cheap and always runs. What it builds is an
/// `EquatableView` around a private view whose `==` compares nothing but `key`,
/// so when the key is unchanged SwiftUI never calls the content closure at all.
/// The closure is the expensive part; not calling it is the saving.
///
/// ## The one way to get this wrong
///
/// The content closure receives the key as its argument, and that is not a
/// convenience — it is the safe way to write it. Anything the closure captures
/// *instead of* reading from the key is invisible to `==`, so the memoised
/// content will go on displaying the value it was built with:
///
/// ```swift
/// // Wrong: `count` is not part of the key, so the badge freezes at its
/// // first value while the title keeps it up to date.
/// Memoized(item.title) { title in
///     Label(title, systemImage: "tray")
///         .badge(viewModel.count)
/// }
///
/// // Right: everything the content reads is in the key.
/// Memoized(MemoKey(title: item.title, count: viewModel.count)) { key in
///     Label(key.title, systemImage: "tray")
///         .badge(key.count)
/// }
/// ```
///
/// A stale view is a worse defect than a redundant body evaluation, so reach
/// for this only where the key genuinely covers what the content renders.
package struct Memoized<Key: Equatable & Sendable, Content: View>: View {

    private let key: Key
    private let content: (Key) -> Content

    package init(_ key: Key, @ViewBuilder content: @escaping (Key) -> Content) {
        self.key = key
        self.content = content
    }

    package var body: some View {
        EquatableView(content: Contents(key: key, content: content))
    }

    // MARK: - The compared view

    /// The view whose equality decides whether the content closure runs.
    ///
    /// `==` deliberately ignores `content`. Two closures are not comparable in
    /// Swift, and comparing them by identity would defeat the whole type — a
    /// closure written inline in a body is a fresh value on every evaluation,
    /// so an identity comparison would never find two of them equal.
    ///
    /// It is `nonisolated` because it must be: `View` is `@MainActor`, so an
    /// operator declared inside one is main-actor isolated by inference and
    /// cannot satisfy `Equatable`'s nonisolated requirement. That in turn is
    /// why `Key` is constrained to `Sendable` — reading `key` from a
    /// nonisolated context is only allowed for an immutable property whose
    /// type can cross an isolation boundary. The constraint costs nothing a
    /// memo key should ever have: a key is a value the framework compares off
    /// the back of a diff, not a reference into the screen's state.
    private struct Contents: View, Equatable {
        let key: Key
        let content: (Key) -> Content

        nonisolated static func == (lhs: Contents, rhs: Contents) -> Bool {
            lhs.key == rhs.key
        }

        var body: some View {
            content(key)
        }
    }
}

// MARK: - Preview

/// Drives one value that changes constantly past two subtrees that do not care
/// about it, so the difference the memoisation makes is on screen rather than
/// only in a test.
@Observable
@MainActor
private final class MemoPreviewModel {
    var ticks = 0
    var title = "Quarterly report"
}

private struct MemoizedPreview: View {
    @State private var model = MemoPreviewModel()
    @State private var ledger = BodyEvaluationLedger()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Ticks: \(model.ticks)")
                .font(.title2.monospacedDigit())

            VStack(alignment: .leading, spacing: 8) {
                BodyEvaluationProbe("inline", into: ledger)
                Text("Built inline: \(ledger.count(of: "inline")) evaluations")
                Text(model.title)
                    .font(.headline)
            }

            // The count this branch reads is captured rather than keyed, which
            // the documentation above warns about — and is exactly right here:
            // it only changes when this closure runs, so it cannot go stale
            // against what is on screen.
            Memoized(model.title) { title in
                VStack(alignment: .leading, spacing: 8) {
                    BodyEvaluationProbe("memoized", into: ledger)
                    Text("Memoised: \(ledger.count(of: "memoized")) evaluations")
                    Text(title)
                        .font(.headline)
                }
            }

            HStack {
                Button("Tick") { model.ticks += 1 }
                Button("Rename") { model.title = "Quarterly report \(model.ticks)" }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}

#Preview("Memoised vs inline content") {
    MemoizedPreview()
}
