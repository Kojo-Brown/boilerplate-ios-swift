import CoreGraphics

// MARK: - Engine

/// The geometry behind ``FlowLayout``, with no SwiftUI in it.
///
/// A `Layout` conformance cannot be unit tested directly: `sizeThatFits` and
/// `placeSubviews` both take a `LayoutSubviews`, and there is no initialiser
/// for one — the only way to get a value of that type is to be called by
/// SwiftUI, inside a tree SwiftUI is driving. Every arithmetic decision a flow
/// makes would therefore be reachable only through a hosted view, a simulator
/// and a 50 ms settle, which is an expensive and flaky place to assert that a
/// line breaks at the right item.
///
/// So the arithmetic lives here, as values in and values out, and
/// ``FlowLayout`` is the adapter that measures `LayoutSubviews` into ``Item``s
/// and places the ``Solution`` that comes back. The hosted test then has one job
/// — proving the adapter wires the two ends together — while the line
/// breaking, the alignment and the overflow cases are ordinary unit tests that
/// run anywhere.
///
/// Coordinates in a ``Solution`` are relative to the layout's own origin, not to
/// any container's. ``FlowLayout`` offsets them by `bounds.origin` when it
/// places, which is the one thing a `Layout` must never forget to do.
package struct FlowLayoutEngine: Equatable, Sendable {

    // MARK: - Inputs

    /// Which edge the flow starts from.
    ///
    /// A `Layout` conformance does **not** get right-to-left for free, and
    /// this is the part of that fact that is easy to miss: SwiftUI mirrors its
    /// own containers, but `placeSubviews` hands a custom layout a `bounds`
    /// whose `x` grows to the right under every layout direction there is. So
    /// a flow that places its first item at `x == 0` places it at the *left*
    /// edge in Arabic and Hebrew, reading order runs the wrong way, and
    /// `.leading` — a word that means "start", not "left" — quietly means
    /// "left" for this one container while meaning "right" for every `HStack`
    /// beside it.
    ///
    /// Nothing catches that either. The layout is valid, the arithmetic is
    /// correct, and the defect is visible only in a language the previews are
    /// not written in. `LayoutSubviews.layoutDirection` is the environment
    /// value SwiftUI provides precisely so a `Layout` can answer it, and
    /// ``FlowLayout`` reads it and passes it here.
    ///
    /// Declared here rather than reusing `SwiftUI.LayoutDirection` because
    /// this file has no SwiftUI in it — that is what lets the geometry be unit
    /// tested without a host — and the adapter maps between the two.
    package enum WritingDirection: Equatable, Sendable {
        case leftToRight
        case rightToLeft
    }

    /// Where a line's content sits when the line is narrower than the widest
    /// line in the flow.
    ///
    /// The flow reports the width it actually used — see ``Solution/size`` — so
    /// this is alignment of the short lines against the long ones, not against
    /// whatever the parent proposed.
    /// `leading` and `trailing` are the *reading* edges, so they swap with
    /// ``WritingDirection`` exactly as the same words do on an `HStack`.
    package enum Alignment: Equatable, Sendable {
        case leading
        case center
        case trailing
    }

    /// How items of differing heights sit against each other within one line.
    package enum LineAlignment: Equatable, Sendable {
        case top
        case center
        case bottom
        /// Baselines coincide, the way `HStack(alignment: .firstTextBaseline)`
        /// aligns text of different sizes.
        ///
        /// This is the only mode whose line height is not simply the tallest
        /// item: a line of an 80-point title beside a 12-point caption is as
        /// tall as the deepest ascent plus the deepest descent, which can
        /// exceed both items.
        case firstBaseline
    }

    /// One measured subview.
    package struct Item: Equatable, Sendable {

        /// What the subview reported for an unspecified proposal — its ideal
        /// size. A flow never squeezes an item to make it fit; it wraps.
        package var size: CGSize

        /// The gap this item asks for between itself and the item before it in
        /// reading order, used only when the two end up on the same line.
        /// Dropped when this item starts a line.
        package var leadingSpacing: CGFloat

        /// Distance from the item's top edge down to its first text baseline.
        ///
        /// SwiftUI answers this for every view, not only for text: a view with
        /// no text of its own reports its own height, which is what makes a
        /// colour swatch bottom-align against a label under
        /// ``LineAlignment/firstBaseline``. That is the behaviour `HStack` has,
        /// and copying it is the point.
        package var firstBaseline: CGFloat

        /// - Parameter firstBaseline: `nil` means "no baseline of its own", and
        ///   resolves to the item's height, matching what SwiftUI reports for a
        ///   view containing no text.
        package init(size: CGSize, leadingSpacing: CGFloat = 0, firstBaseline: CGFloat? = nil) {
            self.size = size
            self.leadingSpacing = leadingSpacing
            self.firstBaseline = firstBaseline ?? size.height
        }
    }

    // MARK: - Outputs

    /// One row of the flow.
    package struct Line: Equatable, Sendable {

        /// Indices into the item array this line was built from.
        package var range: Range<Int>

        /// Content width: the items plus the spacing between them, never the
        /// width the line was allowed.
        package var width: CGFloat

        package var height: CGFloat

        /// Offset of the line's top edge from the flow's origin.
        package var minY: CGFloat

        /// Offset of the line's text baseline from the flow's origin.
        ///
        /// The deepest baseline of the items on the line once they are placed,
        /// which is what ``FlowLayout`` hands back from `explicitAlignment` so
        /// a flow can be baseline-aligned against its siblings.
        package var baseline: CGFloat
    }

    package struct Solution: Equatable, Sendable {
        package var lines: [Line]

        /// Frames for every item, in the same order as the items went in.
        package var frames: [CGRect]

        /// The size the flow needs: the widest line by the tallest stack of
        /// them.
        ///
        /// This can exceed the width the lines were formed against, and
        /// deliberately so — see ``FlowLayoutEngine/layout(_:inWidth:)``.
        package var size: CGSize

        package static let empty = Solution(lines: [], frames: [], size: .zero)
    }

    // MARK: - Configuration

    package var alignment: Alignment
    package var lineAlignment: LineAlignment

    /// The reading direction the frames come back in — see ``WritingDirection``.
    package var layoutDirection: WritingDirection

    /// Vertical gap between lines. Uniform, unlike the horizontal spacing —
    /// see ``FlowLayout`` for why the per-pair form is not available here.
    package var lineSpacing: CGFloat

    package init(
        alignment: Alignment = .leading,
        lineAlignment: LineAlignment = .firstBaseline,
        lineSpacing: CGFloat = 8,
        layoutDirection: WritingDirection = .leftToRight
    ) {
        self.alignment = alignment
        self.lineAlignment = lineAlignment
        self.lineSpacing = lineSpacing
        self.layoutDirection = layoutDirection
    }

    /// Slack allowed when deciding whether one more item fits.
    ///
    /// Widths arrive from text measurement and are rarely round, so an item
    /// that fits exactly can land a fraction of a point over the limit and wrap
    /// a line that visibly had room. A twentieth of a point is far below what a
    /// 3x screen can draw and far above the error a few additions accumulate.
    private static let fittingTolerance: CGFloat = 0.05

    // MARK: - Layout

    /// Breaks `items` into lines no wider than `maxWidth` and places them.
    ///
    /// `maxWidth` is a limit on line *breaking*, not on the result. An item
    /// wider than the whole container keeps its width and occupies a line
    /// alone, so the returned size can be wider than `maxWidth`; the
    /// alternative — reporting a size the content does not fit in — is how a
    /// custom layout ends up drawing outside its own bounds with nothing in the
    /// API to say so. `.infinity` puts everything on one line, which is what a
    /// flow's ideal width means.
    package func layout(_ items: [Item], inWidth maxWidth: CGFloat) -> Solution {
        guard !items.isEmpty else { return .empty }

        var result = Solution(lines: [], frames: Array(repeating: .zero, count: items.count), size: .zero)
        var lineStart = 0
        var lineWidth: CGFloat = 0

        for (index, item) in items.enumerated() {
            let spacing = index == lineStart ? 0 : item.leadingSpacing
            let extended = lineWidth + spacing + item.size.width

            // `index > lineStart` is what keeps an over-wide item from wrapping
            // onto an empty line for ever: the first item on a line is always
            // accepted, however wide it is.
            if index > lineStart, extended > maxWidth + Self.fittingTolerance {
                result.lines.append(openLine(lineStart..<index, width: lineWidth))
                lineStart = index
                lineWidth = item.size.width
            } else {
                lineWidth = extended
            }
        }
        result.lines.append(openLine(lineStart..<items.count, width: lineWidth))

        place(items, into: &result)
        result.size = CGSize(
            width: result.lines.map(\.width).max() ?? 0,
            height: (result.lines.last?.minY ?? 0) + (result.lines.last?.height ?? 0)
        )
        if layoutDirection == .rightToLeft {
            mirrorHorizontally(&result)
        }
        return result
    }

    // MARK: - Private

    /// A line that knows which items it holds and how wide they came out.
    ///
    /// Its height, its position and its baseline are filled in by
    /// ``place(_:into:)``: none of the three can be known during breaking,
    /// because all three depend on the last item the line turns out to hold.
    private func openLine(_ range: Range<Int>, width: CGFloat) -> Line {
        Line(range: range, width: width, height: 0, minY: 0, baseline: 0)
    }

    /// Fills in each line's height and baseline and every item's frame.
    ///
    /// Two passes rather than one because a line's height is not known until
    /// its last item has been seen, and every item's `y` depends on it.
    private func place(_ items: [Item], into result: inout Solution) {
        let widest = result.lines.map(\.width).max() ?? 0
        var nextY: CGFloat = 0

        for number in result.lines.indices {
            let line = result.lines[number]
            let members = items[line.range]
            let ascent = members.map(\.firstBaseline).max() ?? 0
            let descent = members.map { $0.size.height - $0.firstBaseline }.max() ?? 0
            let height = lineAlignment == .firstBaseline
                ? ascent + descent
                : members.map(\.size.height).max() ?? 0

            if number > 0 {
                nextY += lineSpacing
            }

            var originX = leadingEdge(ofLineWidth: line.width, widest: widest)
            var baseline = nextY

            for index in line.range {
                let item = items[index]
                if index > line.range.lowerBound {
                    originX += item.leadingSpacing
                }
                let originY = nextY + offset(of: item, inLineOfHeight: height, ascent: ascent)
                result.frames[index] = CGRect(origin: CGPoint(x: originX, y: originY), size: item.size)
                baseline = max(baseline, originY + item.firstBaseline)
                originX += item.size.width
            }

            result.lines[number].height = height
            result.lines[number].minY = nextY
            result.lines[number].baseline = baseline
            nextY += height
        }
    }

    /// Reflects every frame about the flow's vertical centre line.
    ///
    /// One pass at the end rather than a branch inside ``place(_:into:)``,
    /// because a reflection is what right-to-left *is* — it has to reverse the
    /// order items sit in along a line and move each line's content to the
    /// opposite edge, and those are the same operation seen twice. Written as
    /// two special cases inside the placement loop they would be two places to
    /// get the spacing wrong, and the pair only ever agrees by inspection.
    ///
    /// The lines themselves are untouched: a `Line`'s width, height, `minY`
    /// and baseline are all vertical or scalar, and none of them moves.
    ///
    /// Reflecting about ``Solution/size`` rather than about the width the
    /// lines were *broken* at is deliberate, and it is what keeps the flow
    /// inside its own bounds. A flow reports the width it actually used, which
    /// for a short line is narrower than the container; mirroring about the
    /// container width instead would push content past the reported size —
    /// the same class of defect as reporting a size the content does not fit
    /// in, which is how a custom layout ends up drawing outside its bounds.
    private func mirrorHorizontally(_ result: inout Solution) {
        let width = result.size.width
        for index in result.frames.indices {
            result.frames[index].origin.x = width - result.frames[index].maxX
        }
    }

    /// Where a line of `width` starts, given that the flow is only as wide as
    /// its widest line.
    private func leadingEdge(ofLineWidth width: CGFloat, widest: CGFloat) -> CGFloat {
        switch alignment {
        case .leading:  return 0
        case .center:   return (widest - width) / 2
        case .trailing: return widest - width
        }
    }

    /// How far below the line's top edge an item sits.
    private func offset(of item: Item, inLineOfHeight height: CGFloat, ascent: CGFloat) -> CGFloat {
        switch lineAlignment {
        case .top:           return 0
        case .center:        return (height - item.size.height) / 2
        case .bottom:        return height - item.size.height
        case .firstBaseline: return ascent - item.firstBaseline
        }
    }
}
