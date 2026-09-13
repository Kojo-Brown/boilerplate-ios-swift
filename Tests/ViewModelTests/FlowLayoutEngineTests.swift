import CoreGraphics
import Testing
@testable import Features

// MARK: - Fixtures

/// A square-cornered item with no baseline of its own, which is the shape most
/// of the line-breaking tests care about.
private func item(
    width: CGFloat,
    height: CGFloat = 40,
    spacing: CGFloat = 8,
    baseline: CGFloat? = nil
) -> FlowLayoutEngine.Item {
    FlowLayoutEngine.Item(
        size: CGSize(width: width, height: height),
        leadingSpacing: spacing,
        firstBaseline: baseline
    )
}

/// Comparison at a scale finer than any screen can draw.
///
/// Exact equality would be asserting that the engine happens to add its terms
/// in the order this test does, which is not a property worth freezing.
private func isClose(_ lhs: CGFloat, _ rhs: CGFloat, within tolerance: CGFloat = 0.001) -> Bool {
    abs(lhs - rhs) <= tolerance
}

private func isClose(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
    isClose(lhs.x, rhs.x) && isClose(lhs.y, rhs.y)
}

private func isClose(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
    isClose(lhs.width, rhs.width) && isClose(lhs.height, rhs.height)
}

// MARK: - Geometry

/// Phase 10 item 4. The arithmetic behind ``FlowLayout``, tested where it can
/// be: as values in and values out, with no simulator, no hosting controller
/// and no settle.
///
/// What is deliberately *not* here is whether SwiftUI calls the layout with
/// the measurements these tests assume — that is the adapter's job and
/// `FlowLayoutRenderTests` is where it is checked, against a real tree.
@Suite("FlowLayoutEngine geometry")
struct FlowLayoutEngineTests {

    // MARK: - Line breaking

    @Test("No items lays out to nothing rather than to a zero-height line")
    func emptyInputProducesNoLines() {
        let solution = FlowLayoutEngine().layout([], inWidth: 320)

        #expect(solution.lines.isEmpty)
        #expect(solution.frames.isEmpty)
        #expect(solution.size == .zero)
    }

    @Test("Items wrap at the first one that does not fit")
    func itemsWrapWhenTheLineIsFull() {
        let engine = FlowLayoutEngine(lineAlignment: .top, lineSpacing: 10)
        let items = Array(repeating: item(width: 100), count: 3)

        let solution = engine.layout(items, inWidth: 250)

        #expect(solution.lines.map(\.range) == [0..<2, 2..<3])
        #expect(isClose(solution.frames[0].origin, CGPoint(x: 0, y: 0)))
        #expect(isClose(solution.frames[1].origin, CGPoint(x: 108, y: 0)))
        #expect(isClose(solution.frames[2].origin, CGPoint(x: 0, y: 50)))
        #expect(isClose(solution.size, CGSize(width: 208, height: 90)))
    }

    /// The spacing an item asks for is spacing *between neighbours*. Carrying
    /// it onto a wrapped item would indent every line after the first by one
    /// gap, which reads as a bug in the alignment rather than in the spacing.
    @Test("An item that starts a line drops its leading spacing")
    func wrappedItemStartsAtTheLeadingEdge() {
        let engine = FlowLayoutEngine(lineAlignment: .top, lineSpacing: 0)
        let items = Array(repeating: item(width: 100, spacing: 30), count: 2)

        let solution = engine.layout(items, inWidth: 100)

        #expect(solution.lines.map(\.range) == [0..<1, 1..<2])
        #expect(isClose(solution.frames[1].origin.x, 0))
    }

    @Test("Everything fits on one line when the width allows it")
    func oneLineWhenEverythingFits() {
        let engine = FlowLayoutEngine(lineAlignment: .top)
        let items = Array(repeating: item(width: 100), count: 3)

        let solution = engine.layout(items, inWidth: 1000)

        #expect(solution.lines.map(\.range) == [0..<3])
        #expect(isClose(solution.size, CGSize(width: 316, height: 40)))
    }

    /// An infinite width is SwiftUI asking what the flow would *like* to be.
    @Test("An infinite width reports the single-line ideal size")
    func infiniteWidthIsOneLine() {
        let engine = FlowLayoutEngine(lineAlignment: .top)
        let items = Array(repeating: item(width: 100), count: 4)

        let solution = engine.layout(items, inWidth: .infinity)

        #expect(solution.lines.count == 1)
        #expect(isClose(solution.size.width, 424))
    }

    /// The opposite question, and the one a `List` row asks when it is deciding
    /// how narrow a cell may be.
    @Test("A width of zero puts every item on its own line")
    func zeroWidthIsOneItemPerLine() {
        let engine = FlowLayoutEngine(lineAlignment: .top, lineSpacing: 10)
        let items = [item(width: 100), item(width: 60), item(width: 140)]

        let solution = engine.layout(items, inWidth: 0)

        #expect(solution.lines.map(\.range) == [0..<1, 1..<2, 2..<3])
        #expect(isClose(solution.size, CGSize(width: 140, height: 140)))
    }

    /// The honesty case. A flow cannot shrink an item — it has no say in how
    /// wide a chip's text is — so when one does not fit it reports a size that
    /// does not fit either, rather than a size that would have the item drawn
    /// outside the bounds its parent gave it.
    @Test("An item wider than the container keeps its width and reports the overflow")
    func overWideItemOverflowsRatherThanBeingSqueezed() {
        let engine = FlowLayoutEngine(lineAlignment: .top, lineSpacing: 0)
        let items = [item(width: 300), item(width: 50)]

        let solution = engine.layout(items, inWidth: 200)

        #expect(solution.lines.map(\.range) == [0..<1, 1..<2])
        #expect(isClose(solution.frames[0].width, 300))
        #expect(isClose(solution.size.width, 300))
    }

    @Test("An item that overshoots by less than a twentieth of a point still fits")
    func fittingToleranceAbsorbsMeasurementNoise() {
        let engine = FlowLayoutEngine(lineAlignment: .top)
        let items = Array(repeating: item(width: 100), count: 2)

        #expect(engine.layout(items, inWidth: 207.98).lines.count == 1)
        #expect(engine.layout(items, inWidth: 207.5).lines.count == 2)
    }

    // MARK: - Alignment within a line

    @Test("Top alignment hangs every item from the top of its line")
    func topAlignmentPinsItemsToTheLineTop() {
        let engine = FlowLayoutEngine(lineAlignment: .top)
        let items = [item(width: 100, height: 40), item(width: 100, height: 20)]

        let solution = engine.layout(items, inWidth: 1000)

        #expect(isClose(solution.frames[0].origin.y, 0))
        #expect(isClose(solution.frames[1].origin.y, 0))
        #expect(isClose(solution.lines[0].height, 40))
    }

    @Test("Centre alignment centres the shorter item in the line")
    func centreAlignmentCentresWithinTheLine() {
        let engine = FlowLayoutEngine(lineAlignment: .center)
        let items = [item(width: 100, height: 40), item(width: 100, height: 20)]

        let solution = engine.layout(items, inWidth: 1000)

        #expect(isClose(solution.frames[0].origin.y, 0))
        #expect(isClose(solution.frames[1].origin.y, 10))
    }

    @Test("Bottom alignment sits every item on the line's bottom edge")
    func bottomAlignmentSitsItemsOnTheLineBase() {
        let engine = FlowLayoutEngine(lineAlignment: .bottom)
        let items = [item(width: 100, height: 40), item(width: 100, height: 20)]

        let solution = engine.layout(items, inWidth: 1000)

        #expect(isClose(solution.frames[0].origin.y, 0))
        #expect(isClose(solution.frames[1].origin.y, 20))
    }

    /// The mode that is not simply "the tallest item wins". A line holding a
    /// deep ascent and a deep descent is taller than either item, and getting
    /// this wrong is invisible until two fonts differ enough to notice.
    @Test("Baseline alignment lines the baselines up and can exceed the tallest item")
    func baselineAlignmentAlignsBaselines() {
        let engine = FlowLayoutEngine(lineAlignment: .firstBaseline)
        let items = [
            item(width: 100, height: 80, baseline: 60),
            item(width: 100, height: 50, baseline: 10),
        ]

        let solution = engine.layout(items, inWidth: 1000)

        #expect(isClose(solution.frames[0].origin.y, 0))
        #expect(isClose(solution.frames[1].origin.y, 50))
        #expect(isClose(solution.lines[0].height, 100))
        #expect(isClose(solution.lines[0].baseline, 60))
    }

    @Test("An item with no baseline of its own is treated as having one at its foot")
    func missingBaselineDefaultsToTheItemFoot() {
        let measured = FlowLayoutEngine.Item(size: CGSize(width: 10, height: 24))

        #expect(isClose(measured.firstBaseline, 24))
    }

    // MARK: - Alignment of the lines themselves

    @Test("Leading alignment starts every line at the same edge")
    func leadingAlignmentStartsEveryLineAtZero() {
        let engine = FlowLayoutEngine(alignment: .leading, lineAlignment: .top, lineSpacing: 0)
        let items = Array(repeating: item(width: 100), count: 3)

        let solution = engine.layout(items, inWidth: 250)

        #expect(isClose(solution.frames[0].origin.x, 0))
        #expect(isClose(solution.frames[2].origin.x, 0))
    }

    /// Short lines are centred against the widest line, not against whatever
    /// the parent proposed — the flow reports the width it used, so there is no
    /// other width to centre in.
    @Test("Centre alignment centres a short line against the widest one")
    func centreAlignmentCentresShortLines() {
        let engine = FlowLayoutEngine(alignment: .center, lineAlignment: .top, lineSpacing: 0)
        let items = Array(repeating: item(width: 100), count: 3)

        let solution = engine.layout(items, inWidth: 250)

        #expect(isClose(solution.frames[2].origin.x, 54))
    }

    @Test("Trailing alignment ends a short line on the widest line's trailing edge")
    func trailingAlignmentPushesShortLinesRight() {
        let engine = FlowLayoutEngine(alignment: .trailing, lineAlignment: .top, lineSpacing: 0)
        let items = Array(repeating: item(width: 100), count: 3)

        let solution = engine.layout(items, inWidth: 250)

        #expect(isClose(solution.frames[2].origin.x, 108))
    }

    // MARK: - Line spacing

    @Test("Line spacing goes between lines and not above the first or below the last")
    func lineSpacingIsBetweenLinesOnly() {
        let engine = FlowLayoutEngine(lineAlignment: .top, lineSpacing: 12)
        let items = Array(repeating: item(width: 100), count: 3)

        let solution = engine.layout(items, inWidth: 100)

        #expect(solution.lines.count == 3)
        #expect(isClose(solution.lines[0].minY, 0))
        #expect(isClose(solution.lines[1].minY, 52))
        #expect(isClose(solution.lines[2].minY, 104))
        #expect(isClose(solution.size.height, 144))
    }
}

// MARK: - Cache

/// What the cache is for, stated as counts.
///
/// The frames a flow produces are the same whether or not anything is cached,
/// so no assertion about geometry can tell a cache that works from one that
/// silently re-measures on every probe. These are the tests that can.
@Suite("FlowLayoutCache")
struct FlowLayoutCacheTests {

    private static let items = [
        FlowLayoutEngine.Item(size: CGSize(width: 100, height: 40), leadingSpacing: 8),
        FlowLayoutEngine.Item(size: CGSize(width: 100, height: 40), leadingSpacing: 8),
        FlowLayoutEngine.Item(size: CGSize(width: 100, height: 40), leadingSpacing: 8),
    ]

    private static let measurements = FlowLayoutCache.Measurements(
        items: Self.items,
        derivedLineSpacing: 12
    )

    private func solve(_ cache: inout FlowLayoutCache, width: CGFloat) -> FlowLayoutEngine.Solution {
        cache.solution(
            forWidth: width,
            measuring: { Self.measurements },
            engine: { measurements in
                FlowLayoutEngine(lineAlignment: .top, lineSpacing: measurements.derivedLineSpacing)
            }
        )
    }

    @Test("A fresh cache measures once and solves once")
    func firstSolveMeasuresAndSolves() {
        var cache = FlowLayoutCache()

        _ = solve(&cache, width: 250)

        #expect(cache.measurePasses == 1)
        #expect(cache.solvePasses == 1)
        #expect(cache.measuredCount == 3)
    }

    @Test("Asking again at the same width does no work at all")
    func repeatedSolveAtTheSameWidthIsFree() {
        var cache = FlowLayoutCache()

        let first = solve(&cache, width: 250)
        let second = solve(&cache, width: 250)

        #expect(first == second)
        #expect(cache.measurePasses == 1)
        #expect(cache.solvePasses == 1)
    }

    /// The point of the split. SwiftUI probes a layout at several widths before
    /// it commits to one, and every probe after the first should cost line
    /// breaking and nothing else.
    @Test("A different width re-breaks the lines without re-measuring")
    func differentWidthReusesTheMeasurements() {
        var cache = FlowLayoutCache()

        _ = solve(&cache, width: 250)
        _ = solve(&cache, width: .infinity)
        let narrow = solve(&cache, width: 100)

        #expect(cache.measurePasses == 1)
        #expect(cache.solvePasses == 3)
        #expect(narrow.lines.count == 3)
    }

    @Test("Invalidating clears the counters as well as the measurements")
    func invalidationResetsEverything() {
        var cache = FlowLayoutCache()
        _ = solve(&cache, width: 250)

        cache.invalidate()

        #expect(cache.measurePasses == 0)
        #expect(cache.solvePasses == 0)
        #expect(cache.measuredCount == nil)

        _ = solve(&cache, width: 250)
        #expect(cache.measurePasses == 1)
    }

    /// The engine is built per solve rather than stored, so that a caller who
    /// named no line spacing gets the one derived from the subviews — a value
    /// that does not exist until they have been measured.
    @Test("The engine is built from the measurements, so derived spacing reaches the geometry")
    func derivedLineSpacingReachesTheEngine() {
        var cache = FlowLayoutCache()

        let solution = solve(&cache, width: 100)

        #expect(solution.lines.count == 3)
        #expect(isClose(solution.lines[1].minY, 52))
    }
}
