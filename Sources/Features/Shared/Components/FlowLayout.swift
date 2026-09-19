import SwiftUI

// MARK: - Cache

/// What ``FlowLayout`` keeps between the calls SwiftUI makes while laying it
/// out once.
///
/// `Layout` is not called once per pass. SwiftUI probes a layout with several
/// proposals before it commits to one — typically the zero size, the infinite
/// size and the size it actually has — and then calls `placeSubviews` with the
/// winner. A flow answers each of those by measuring every subview and then
/// breaking lines, and measuring a subview is not free: it runs the text
/// layout for a `Text`, and a chip row of forty tags measured four times is a
/// hundred and sixty text measurements for one frame.
///
/// Only the second half of that work depends on the proposal. The measurements
/// do not — an item's ideal size is the same whatever width it is going to be
/// broken into — so they are taken once and reused, while the line breaking is
/// cached against the width it was done for. `measurePasses` and `solvePasses`
/// are not diagnostics left in by accident: they are how
/// `FlowLayoutCacheTests` asserts that four probes cost one measurement, which
/// is a claim no assertion about the resulting frames can make.
package struct FlowLayoutCache {

    /// Everything read out of the subviews themselves, in the order they were
    /// given.
    package struct Measurements: Equatable, Sendable {
        package var items: [FlowLayoutEngine.Item]

        /// The line spacing to use when the caller did not name one: the
        /// largest vertical gap any adjacent pair of subviews asked for.
        ///
        /// SwiftUI's spacing is a property of a *pair* of views, so the exact
        /// answer would be the gap between the last item of one line and the
        /// first of the next — which cannot be known here, because which items
        /// those are is decided by the line breaking this value is an input
        /// to. Resolving it afterwards, per line, was the alternative and is
        /// worse than it sounds: the gap between two rows of chips would then
        /// depend on which chip happened to land at the end of a row, so
        /// widening the container by a point could change the spacing between
        /// rows that did not move. One value for the whole flow is stable
        /// under reflow, which is the property that matters for a container
        /// whose whole purpose is to reflow.
        package var derivedLineSpacing: CGFloat

        package init(items: [FlowLayoutEngine.Item], derivedLineSpacing: CGFloat) {
            self.items = items
            self.derivedLineSpacing = derivedLineSpacing
        }
    }

    private var measurements: Measurements?
    private var solvedWidth: CGFloat?
    private var solvedEngine: FlowLayoutEngine?
    private var solution: FlowLayoutEngine.Solution?

    /// How many times the subviews have been measured since the cache was last
    /// invalidated.
    package private(set) var measurePasses = 0

    /// How many times the engine has broken lines since the cache was last
    /// invalidated.
    package private(set) var solvePasses = 0

    /// How many items the cached measurements cover, or `nil` when nothing has
    /// been measured yet.
    package var measuredCount: Int? { measurements?.items.count }

    package init() {}

    /// Drops everything measured and everything solved.
    ///
    /// The counters go with it. They describe one layout of one set of
    /// subviews; carrying them across an invalidation would make them a tally
    /// of the view's whole lifetime, which answers a different question.
    package mutating func invalidate() {
        measurements = nil
        solvedWidth = nil
        solvedEngine = nil
        solution = nil
        measurePasses = 0
        solvePasses = 0
    }

    /// The flow broken into lines at `width`, measuring and solving only what
    /// has not already been done.
    ///
    /// - Parameters:
    ///   - measure: Called at most once per invalidation.
    ///   - makeEngine: Called on every solve, and the engine it returns is
    ///     half of the cache key. It has to be: it may depend on the
    ///     measurements — that is how a caller that named no line spacing gets
    ///     the derived one — and it carries the layout direction, which is an
    ///     environment value that can change without the subviews or the width
    ///     changing. Keyed on width alone, a flow that flipped to right-to-left
    ///     would go on placing the frames it solved for left-to-right.
    ///     Building one is a struct initialiser over four scalars, so paying
    ///     for it per probe is cheaper than the branch that avoids it.
    package mutating func solution(
        forWidth width: CGFloat,
        measuring measure: () -> Measurements,
        engine makeEngine: (Measurements) -> FlowLayoutEngine
    ) -> FlowLayoutEngine.Solution {
        let measured: Measurements
        if let measurements {
            measured = measurements
        } else {
            measurePasses += 1
            measured = measure()
            measurements = measured
        }

        let engine = makeEngine(measured)
        if let solution, solvedWidth == width, solvedEngine == engine {
            return solution
        }

        solvePasses += 1
        let fresh = engine.layout(measured.items, inWidth: width)
        solution = fresh
        solvedWidth = width
        solvedEngine = engine
        return fresh
    }
}

// MARK: - FlowLayout

/// A container that lays its subviews out in reading order and wraps to a new
/// line when the next one does not fit — a row of tags, a keyword cloud, a set
/// of filter chips.
///
/// ```swift
/// FlowLayout(spacing: 8, lineSpacing: 8) {
///     ForEach(article.tags, id: \.self) { tag in
///         TagChip(tag)
///     }
/// }
/// ```
///
/// ## Why this is a `Layout` and not a stack
///
/// Every SwiftUI container that ships can place these chips; none of them can
/// decide *where the line breaks*, and that is the whole component.
///
/// * `HStack` does not wrap. Past the trailing edge it compresses its
///   subviews, and a chip whose label has been truncated to "Photog…" is a
///   worse outcome than a second row.
/// * `LazyVGrid` wraps, into a column grid: every cell in a column is as wide
///   as the widest thing in it. Tags are not a grid — "iOS" and
///   "Structured Concurrency" want to be their own widths, and a grid either
///   pads the short one or squeezes the long one.
/// * `VStack` of `HStack`s wraps only if something has already decided which
///   chip goes in which row, and nothing in the view tree can: the text has
///   not been measured yet.
///
/// That last point is what makes this *measure-dependent*. The answer depends
/// on the rendered width of every subview before it, which only exists after
/// layout has started — so it cannot be computed in a `body`, and
/// `GeometryReader` cannot help either, because it reports the space available
/// to the container rather than the size of anything inside it. `Layout` is
/// the API that hands a view the measurements, and this is the shape of
/// problem it exists for.
///
/// ## Spacing
///
/// `spacing` and `lineSpacing` are optional, and `nil` means "ask the
/// subviews" rather than "no gap". SwiftUI views carry spacing preferences —
/// two pieces of text want less air between them than a text and an image —
/// and a container that hardcodes a number throws that away. Horizontal
/// spacing is resolved per adjacent pair, exactly as `HStack` does it; line
/// spacing is one value for the whole flow, for the reason recorded on
/// ``FlowLayoutCache/Measurements/derivedLineSpacing``.
///
/// ## Right-to-left
///
/// Handled, and it had to be handled by hand: SwiftUI does not mirror a custom
/// `Layout`, so `bounds.minX` is the left edge in Arabic exactly as it is in
/// English. `subviews.layoutDirection` is the value that says which one the
/// reader is in; it is read here and answered by the engine. See
/// ``FlowLayoutEngine/WritingDirection`` for what goes wrong without it.
package struct FlowLayout: Layout {

    package typealias Cache = FlowLayoutCache

    /// Where short lines sit relative to the longest one.
    package var alignment: FlowLayoutEngine.Alignment

    /// How items of differing heights sit within a line.
    package var lineAlignment: FlowLayoutEngine.LineAlignment

    /// Horizontal gap between neighbours on a line. `nil` resolves per pair
    /// from the subviews' own spacing preferences.
    package var spacing: CGFloat?

    /// Vertical gap between lines. `nil` resolves from the subviews' own
    /// spacing preferences.
    package var lineSpacing: CGFloat?

    package init(
        alignment: FlowLayoutEngine.Alignment = .leading,
        lineAlignment: FlowLayoutEngine.LineAlignment = .firstBaseline,
        spacing: CGFloat? = nil,
        lineSpacing: CGFloat? = nil
    ) {
        self.alignment = alignment
        self.lineAlignment = lineAlignment
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    // MARK: - Cache lifecycle

    package func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    /// SwiftUI calls this when the subviews change, which is the signal that
    /// everything measured is stale.
    ///
    /// Invalidating unconditionally rather than diffing is deliberate: a
    /// subview whose text changed keeps its identity and its position, so
    /// there is nothing in `subviews` to compare against what was measured,
    /// and a cache that kept a stale width would lay the flow out against a
    /// label that is no longer there. The measurements are one pass over the
    /// subviews; a wrong line break is a visible defect.
    package func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.invalidate()
    }

    // MARK: - Layout

    package func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        solve(width: breakingWidth(for: proposal, fallback: .infinity), subviews: subviews, cache: &cache).size
    }

    package func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let width = breakingWidth(for: proposal, fallback: bounds.width)
        let solution = solve(width: width, subviews: subviews, cache: &cache)

        for index in subviews.indices {
            let frame = solution.frames[index]
            subviews[index].place(
                // `bounds` is where the parent put this flow, and it is not
                // necessarily at the origin. The engine works in the flow's own
                // coordinates — already mirrored, under a right-to-left reader
                // — so every frame is offset by it here, the one line whose
                // absence looks like "the layout works, it is just in the
                // wrong place".
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                // Each subview is proposed exactly what it was measured at, so
                // a view that sizes itself to the proposal (a `Rectangle`, a
                // `.frame(maxWidth:)`) lands on the size the line breaking was
                // done with rather than expanding to fill the flow.
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    /// Lets a flow baseline-align against its siblings.
    ///
    /// Without this a `FlowLayout` inside an `HStack(alignment:
    /// .firstTextBaseline)` is aligned by the fallback SwiftUI uses for a
    /// container that declares no baseline of its own — its bottom edge — so
    /// the label beside it sits level with the last row of chips rather than
    /// the first. The first line's baseline is the answer for
    /// `.firstTextBaseline` and the last line's for `.lastTextBaseline`; every
    /// other guide is left to SwiftUI, which is what returning `nil` means.
    package func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGFloat? {
        let width = breakingWidth(for: proposal, fallback: bounds.width)
        let solution = solve(width: width, subviews: subviews, cache: &cache)

        switch guide {
        case .firstTextBaseline: return solution.lines.first.map { bounds.minY + $0.baseline }
        case .lastTextBaseline:  return solution.lines.last.map { bounds.minY + $0.baseline }
        default:                 return nil
        }
    }

    // MARK: - Private

    /// The width line breaking is done against.
    ///
    /// An unspecified or infinite proposal is a question about the flow's
    /// ideal width — "how wide would you like to be?" — and the answer for a
    /// flow is one line. A proposal of zero is the opposite question and is
    /// deliberately *not* clamped up to something usable: breaking at zero puts
    /// every item on its own line, so the reported width is the widest single
    /// item, which is exactly the minimum width a flow can be drawn at without
    /// truncating anything.
    private func breakingWidth(for proposal: ProposedViewSize, fallback: CGFloat) -> CGFloat {
        guard let width = proposal.width, width.isFinite else { return fallback }
        return max(0, width)
    }

    private func solve(
        width: CGFloat,
        subviews: Subviews,
        cache: inout Cache
    ) -> FlowLayoutEngine.Solution {
        // A cache that has outlived the subviews it describes would index its
        // frame array out of bounds below. `updateCache` is SwiftUI's promise
        // that this cannot happen; this is what makes a broken promise a reflow
        // rather than a crash.
        if let measured = cache.measuredCount, measured != subviews.count {
            cache.invalidate()
        }

        return cache.solution(
            forWidth: width,
            measuring: { measurements(of: subviews) },
            engine: { measured in
                FlowLayoutEngine(
                    alignment: alignment,
                    lineAlignment: lineAlignment,
                    lineSpacing: lineSpacing ?? measured.derivedLineSpacing,
                    layoutDirection: Self.writingDirection(of: subviews.layoutDirection)
                )
            }
        )
    }

    /// Maps SwiftUI's environment value onto the engine's own, which exists so
    /// that the geometry stays testable without SwiftUI around it.
    ///
    /// `@unknown default` rather than an exhaustive switch because
    /// `LayoutDirection` is a non-frozen enum in a system framework: a third
    /// case added in some future SDK must not stop this compiling, and
    /// left-to-right is the safer thing to fall back to.
    private static func writingDirection(
        of direction: LayoutDirection
    ) -> FlowLayoutEngine.WritingDirection {
        switch direction {
        case .rightToLeft: .rightToLeft
        case .leftToRight: .leftToRight
        @unknown default:  .leftToRight
        }
    }

    /// Reads every subview's ideal size, its baseline and the gap it wants
    /// from the one before it.
    ///
    /// `.unspecified` rather than the flow's own proposal, because an item's
    /// ideal width is what decides which line it lands on: proposing the
    /// container's width instead would let a `Text` wrap itself to fill the
    /// row, and a flow of one very long tag per line is not a flow.
    private func measurements(of subviews: Subviews) -> Cache.Measurements {
        var items: [FlowLayoutEngine.Item] = []
        items.reserveCapacity(subviews.count)
        var derivedLineSpacing: CGFloat = 0

        for index in subviews.indices {
            let subview = subviews[index]
            let dimensions = subview.dimensions(in: .unspecified)
            var leadingSpacing: CGFloat = 0

            if index > subviews.startIndex {
                let previous = subviews[index - 1].spacing
                leadingSpacing = spacing ?? previous.distance(to: subview.spacing, along: .horizontal)
                derivedLineSpacing = max(
                    derivedLineSpacing,
                    previous.distance(to: subview.spacing, along: .vertical)
                )
            }

            items.append(
                FlowLayoutEngine.Item(
                    size: CGSize(width: dimensions.width, height: dimensions.height),
                    leadingSpacing: leadingSpacing,
                    firstBaseline: dimensions[VerticalAlignment.firstTextBaseline]
                )
            )
        }

        return Cache.Measurements(items: items, derivedLineSpacing: derivedLineSpacing)
    }
}
