import CoreGraphics
import Testing
@testable import Features

// MARK: - Fixtures

/// Three 100-point chips with 8 points between them, broken at 250.
///
/// The numbers are chosen so every expectation below is exact rather than
/// approximate: two chips and one gap is 208, a third would be 316, so the
/// flow is two lines — one full at 208 and one short at 100 — and 208 is the
/// width the whole solution reports. Every mirrored coordinate in this file is
/// `208 − (x + 100)` done by hand.
private let chips = Array(
    repeating: FlowLayoutEngine.Item(size: CGSize(width: 100, height: 40), leadingSpacing: 8),
    count: 3
)

private func solve(
    alignment: FlowLayoutEngine.Alignment = .leading,
    direction: FlowLayoutEngine.WritingDirection
) -> FlowLayoutEngine.Solution {
    FlowLayoutEngine(
        alignment: alignment,
        lineAlignment: .top,
        lineSpacing: 10,
        layoutDirection: direction
    )
    .layout(chips, inWidth: 250)
}

// MARK: - Suite

/// Phase 10 item 7, the right-to-left half.
///
/// The defect these assertions are about is not in this file's arithmetic; it
/// is in an assumption that never appears in the source at all. SwiftUI mirrors
/// the containers it ships — an `HStack` in Arabic lays out right to left with
/// nothing asked of the caller — and a custom `Layout` looks, in a view body,
/// exactly like one of them. It is not one. `placeSubviews` receives a `bounds`
/// whose `x` grows rightwards under every layout direction there is, so a flow
/// that starts at `bounds.minX` starts at the *left* edge in every language,
/// its items run against the reading order, and `.leading` silently means
/// "left" for this one container while meaning "start" for every stack beside
/// it.
///
/// Nothing in the toolchain says so. The layout is valid, the arithmetic is
/// right, and the only way to see it is to run the app in a language none of
/// the previews are written in. `LayoutSubviews.layoutDirection` exists because
/// this is the layout's own responsibility; these tests are what hold the
/// engine to it.
@Suite("FlowLayout mirrors itself for a right-to-left reader")
struct FlowLayoutDirectionTests {

    // MARK: Reading order

    /// The first item is at the *right* and the order runs inwards from there,
    /// which is the whole claim reduced to two coordinates.
    @Test("The first chip on a line sits at the trailing edge")
    func readingOrderReverses() {
        let rightToLeft = solve(direction: .rightToLeft)

        #expect(rightToLeft.frames[0].minX == 108)
        #expect(rightToLeft.frames[1].minX == 0)
    }

    @Test("Left-to-right is untouched")
    func leftToRightIsUnchanged() {
        let leftToRight = solve(direction: .leftToRight)

        #expect(leftToRight.frames[0].minX == 0)
        #expect(leftToRight.frames[1].minX == 108)
        #expect(leftToRight.frames[2].minX == 0)
    }

    /// The gap between neighbours is the gap they asked for, in either
    /// direction. A mirror that reflected each frame about its own centre, or
    /// one that reversed the array instead of the geometry, would move the
    /// chips to the right places and put the spacing in the wrong one.
    @Test("The spacing between neighbours survives the mirror")
    func spacingIsPreserved() {
        let rightToLeft = solve(direction: .rightToLeft)

        #expect(rightToLeft.frames[0].minX - rightToLeft.frames[1].maxX == 8)
    }

    // MARK: Alignment

    /// `.leading` is the *reading* edge, not the left one — the short second
    /// line hangs from the right in Arabic exactly as it hangs from the left in
    /// English.
    @Test("A short line under .leading hangs from the reading edge")
    func leadingIsTheReadingEdge() {
        #expect(solve(alignment: .leading, direction: .leftToRight).frames[2].minX == 0)
        #expect(solve(alignment: .leading, direction: .rightToLeft).frames[2].minX == 108)
    }

    @Test("A short line under .trailing hangs from the other one")
    func trailingIsTheOtherEdge() {
        #expect(solve(alignment: .trailing, direction: .leftToRight).frames[2].minX == 108)
        #expect(solve(alignment: .trailing, direction: .rightToLeft).frames[2].minX == 0)
    }

    /// Centred is the one alignment a mirror cannot move, and asserting it is
    /// what distinguishes "reflected about the flow's own centre line" from
    /// "shifted by some width that happened to work for the other two cases".
    @Test("A centred line does not move")
    func centredLinesAreFixedPoints() {
        #expect(solve(alignment: .center, direction: .leftToRight).frames[2].minX == 54)
        #expect(solve(alignment: .center, direction: .rightToLeft).frames[2].minX == 54)
    }

    // MARK: What must not change

    /// Line breaking happens before the mirror and is unaffected by it: the
    /// same chips wrap at the same place, so the same solution comes back with
    /// its `x` values reflected and nothing else touched.
    @Test("Only the horizontal positions differ")
    func everythingElseIsIdentical() {
        let leftToRight = solve(direction: .leftToRight)
        let rightToLeft = solve(direction: .rightToLeft)

        #expect(rightToLeft.size == leftToRight.size)
        #expect(rightToLeft.lines == leftToRight.lines)
        #expect(rightToLeft.frames.map(\.minY) == leftToRight.frames.map(\.minY))
        #expect(rightToLeft.frames.map(\.size) == leftToRight.frames.map(\.size))
    }

    /// Every chip stays inside the size the flow reported.
    ///
    /// This is the reason the reflection is about ``FlowLayoutEngine/Solution``'s
    /// own width rather than the width the lines were broken at. A flow reports
    /// the width it actually used — 208 here, not the 250 it was offered — and
    /// mirroring about the wider number would push every frame 42 points past
    /// the right edge of a container that had been told the flow was 208 wide.
    /// Frames outside the reported size is the same defect as a size the
    /// content does not fit in, which is how a custom layout draws outside its
    /// own bounds.
    @Test("No frame escapes the reported size")
    func framesStayInsideTheReportedSize() {
        let rightToLeft = solve(direction: .rightToLeft)

        for frame in rightToLeft.frames {
            #expect(frame.minX >= 0)
            #expect(frame.maxX <= rightToLeft.size.width)
        }
    }

    @Test("An empty flow has nothing to mirror")
    func emptyFlowIsUnchanged() {
        let engine = FlowLayoutEngine(layoutDirection: .rightToLeft)

        #expect(engine.layout([], inWidth: 250) == .empty)
    }

    // MARK: The cache

    /// A direction flip has to re-solve, and the cache has no way to know that
    /// from its width alone.
    ///
    /// This is the half of the change that is easy to leave out. Layout
    /// direction is an environment value: it can change while the subviews and
    /// the proposed width both stay exactly as they were, which is precisely
    /// the case a width-keyed cache reports as a hit. The flow would then go on
    /// placing the frames it solved for the other direction — correct
    /// arithmetic, cached under the wrong question. Keying on the engine as
    /// well is what closes it, and this is the assertion that says so.
    @Test("Flipping the direction invalidates a solution cached for the other one")
    func directionIsPartOfTheCacheKey() {
        var cache = FlowLayoutCache()
        let measurements = FlowLayoutCache.Measurements(items: chips, derivedLineSpacing: 10)

        func solveCached(_ direction: FlowLayoutEngine.WritingDirection) -> FlowLayoutEngine.Solution {
            cache.solution(
                forWidth: 250,
                measuring: { measurements },
                engine: { _ in
                    FlowLayoutEngine(lineAlignment: .top, lineSpacing: 10, layoutDirection: direction)
                }
            )
        }

        let leftToRight = solveCached(.leftToRight)
        let rightToLeft = solveCached(.rightToLeft)

        #expect(cache.measurePasses == 1)
        #expect(cache.solvePasses == 2)
        #expect(leftToRight.frames[0].minX == 0)
        #expect(rightToLeft.frames[0].minX == 108)
    }

    /// The other half of that: asking the same question twice is still one
    /// solve. A cache keyed on the engine could easily have become a cache that
    /// never hits, which would be correct and also pointless.
    @Test("The same direction at the same width is still a cache hit")
    func repeatingTheSameQuestionDoesNotResolve() {
        var cache = FlowLayoutCache()
        let measurements = FlowLayoutCache.Measurements(items: chips, derivedLineSpacing: 10)

        for _ in 0..<4 {
            _ = cache.solution(
                forWidth: 250,
                measuring: { measurements },
                engine: { _ in
                    FlowLayoutEngine(lineAlignment: .top, lineSpacing: 10, layoutDirection: .rightToLeft)
                }
            )
        }

        #expect(cache.measurePasses == 1)
        #expect(cache.solvePasses == 1)
    }
}
