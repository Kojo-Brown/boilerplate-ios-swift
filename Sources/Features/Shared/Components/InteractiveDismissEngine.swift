import CoreGraphics

// MARK: - Engine

/// The arithmetic behind an interactive dismissal: what the card looks like
/// while a finger is dragging it, and what happens when the finger lifts.
///
/// It is split out of ``InteractiveDismissLayer`` for the same reason
/// ``FlowLayoutEngine`` is split out of ``FlowLayout`` — a `DragGesture.Value`
/// has no initialiser, so every decision taken inside a gesture callback is
/// reachable only through a hosted view, a simulator and a settle. The
/// decisions are the part worth testing, so they live here as values in and
/// values out, and the layer is the adapter that feeds real drags through them.
///
/// Three properties of a dismissal are easy to get subtly wrong, and all three
/// are decided here rather than in the view:
///
/// * **The threshold is a fraction of the container, not a point count.** A
///   fixed "150 points dismisses" is a quarter of the way down an iPhone SE and
///   a tenth of the way down an iPad, so the same gesture means two different
///   things on two devices. See ``travelFraction``.
/// * **Release is judged on where the drag was *going*, not where it stopped.**
///   A flick that travelled forty points and was still moving at 1,200 points a
///   second is a dismissal; a slow drag that crept to a hundred and stopped is
///   not. See ``projectionFactor``.
/// * **Movement against the dismissal resists rather than tracks.** A card
///   dragged upward that follows the finger one-to-one leaves the screen from
///   the wrong edge and has nowhere to go. See ``rubberBand(_:dimension:)``.
package struct InteractiveDismissEngine: Equatable, Sendable {

    // MARK: - Inputs

    /// A drag at the moment the finger lifts.
    ///
    /// Both members come straight off `DragGesture.Value`, which is the only
    /// reason this type exists: that value cannot be constructed outside a tree
    /// SwiftUI is driving, and a test needs to be able to describe a flick.
    package struct Drag: Equatable, Sendable {

        /// Total movement since the gesture began, in points.
        package var translation: CGSize

        /// Movement per second at the moment of release, as `DragGesture.Value`
        /// reports it.
        package var velocity: CGSize

        /// - Parameter velocity: defaults to standing still, which is what a
        ///   drag that was paused before release actually reports.
        package init(translation: CGSize, velocity: CGSize = .zero) {
            self.translation = translation
            self.velocity = velocity
        }
    }

    // MARK: - Outputs

    /// What the card wears part-way through a drag.
    ///
    /// Every member is derived from the translation alone. Nothing here depends
    /// on velocity, because velocity answers a question that is only asked once
    /// — see ``resolution(for:containerHeight:)`` — and a transform that read it
    /// would flinch whenever the finger changed speed.
    package struct Transform: Equatable, Sendable {

        /// How far the card has moved from its resting position.
        package var offset: CGSize

        /// Uniform scale, between ``InteractiveDismissEngine/scaleFloor`` and 1.
        package var scale: CGFloat

        /// Opacity multiplier for whatever sits behind the card, between 0 and 1.
        package var backdropOpacity: CGFloat

        /// How far the drag has travelled toward a dismissal, clamped to `0...1`.
        package var progress: CGFloat

        /// The card at rest.
        ///
        /// A transform that is not exactly this one for a zero translation is
        /// how a card ends up a hair off-centre, or a shade dim, with nothing
        /// being dragged — which is invisible in a screenshot and obvious in
        /// the hand.
        package static let identity = Transform(
            offset: .zero,
            scale: 1,
            backdropOpacity: 1,
            progress: 0
        )
    }

    /// What to do with the card once the finger has lifted.
    package enum Resolution: Equatable, Sendable {

        /// Take the card away.
        case dismiss

        /// Spring it back to where it started.
        case restore
    }

    // MARK: - Configuration

    /// The fraction of the container's height that counts as a complete
    /// dismissal — the distance at which ``Transform/progress`` reaches 1.
    ///
    /// A quarter of the screen is far enough that a dismissal is deliberate and
    /// short enough that the card is still mostly on screen when it commits, so
    /// the gesture never has to be finished blind.
    package var travelFraction: CGFloat

    /// The projected progress at or above which a release dismisses.
    ///
    /// Below 1 on purpose: the card should leave from wherever the gesture made
    /// its intent clear, not only from the full travel distance. Together with
    /// the projection below, 0.4 of a quarter-screen means a deliberate drag of
    /// roughly ninety points on a phone, or a much shorter flick.
    package var commitProgress: CGFloat

    /// How small the card gets at full progress.
    ///
    /// The floor exists so the card stays a card. Scaling toward zero reads as
    /// the content being destroyed rather than put back, and it is the shrink
    /// itself — not its depth — that says "this is going somewhere".
    package var scaleFloor: CGFloat

    /// The shortest travel distance the engine will measure against, whatever
    /// the container reports.
    ///
    /// A container with no height yet — the first layout pass, a hosted view
    /// that has not been sized — would otherwise make every drag a complete
    /// one, and divide by zero on the way. This is also the floor that keeps a
    /// card inside a small sheet from dismissing on a twitch.
    package var minimumTravel: CGFloat

    /// How much more vertical than horizontal a projected drag must be before
    /// it counts as a dismissal.
    ///
    /// A hero card sits inside scrollable, swipeable surroundings: a mostly
    /// sideways drag is a page turn or a back swipe that happened to drift
    /// down, and dismissing on it is the most annoying possible false positive.
    /// At 1 the drag has to be at least as vertical as it is horizontal.
    package var verticalDominance: CGFloat

    /// - Parameters:
    ///   - minimumTravel: clamped to at least one point, because it is the
    ///     divisor that keeps a zero-height container from producing infinities
    ///     and cannot itself be zero.
    ///   - scaleFloor: clamped to `0...1`; a floor above 1 would grow the card
    ///     as it is dragged away.
    package init(
        travelFraction: CGFloat = 0.25,
        commitProgress: CGFloat = 0.4,
        scaleFloor: CGFloat = 0.82,
        minimumTravel: CGFloat = 88,
        verticalDominance: CGFloat = 1
    ) {
        self.travelFraction = travelFraction
        self.commitProgress = commitProgress
        self.scaleFloor = min(max(scaleFloor, 0), 1)
        self.minimumTravel = max(minimumTravel, 1)
        self.verticalDominance = max(verticalDominance, 0)
    }

    // MARK: - Constants

    /// Seconds of coasting a release is credited with.
    ///
    /// UIKit's own projection, from "Designing Fluid Interfaces" (WWDC18):
    /// `(velocity / 1000) * rate / (1 - rate)` for a deceleration rate of
    /// 0.998 per millisecond, which is `UIScrollView.DecelerationRate.normal`.
    /// That reduces to a constant, and the constant is a duration: a release is
    /// judged as though the card kept moving at its release speed for very
    /// nearly half a second.
    ///
    /// Using the same number as the system means a flick that would have thrown
    /// a scroll view past a paging boundary also dismisses a card, which is the
    /// only definition of "the right amount" that generalises across hands.
    private static let projectionFactor: CGFloat = 0.499

    /// The tension in the overscroll curve, matching `UIScrollView`'s.
    private static let rubberBandCoefficient: CGFloat = 0.55

    // MARK: - Transform

    /// The card's appearance for a drag of `translation` inside a container of
    /// `containerHeight`.
    ///
    /// Horizontal movement tracks the finger exactly and contributes nothing to
    /// progress. That is deliberate: the card is being *held*, so it should go
    /// where it is put, but sideways is not a direction it can leave in — see
    /// ``verticalDominance``.
    package func transform(forTranslation translation: CGSize, containerHeight: CGFloat) -> Transform {
        let travel = travelDistance(inContainerOfHeight: containerHeight)
        let vertical = translation.height >= 0
            ? translation.height
            : -Self.rubberBand(-translation.height, dimension: travel)
        let progress = min(max(vertical / travel, 0), 1)

        return Transform(
            offset: CGSize(width: translation.width, height: vertical),
            scale: 1 - (1 - scaleFloor) * progress,
            backdropOpacity: 1 - progress,
            progress: progress
        )
    }

    // MARK: - Resolution

    /// Whether a released drag dismisses the card or springs it back.
    ///
    /// The translation is projected forward by the release velocity before
    /// anything is measured, so all three of the checks below — direction,
    /// dominance and distance — are asked about where the gesture was heading
    /// rather than where the finger happened to stop.
    package func resolution(for drag: Drag, containerHeight: CGFloat) -> Resolution {
        let projected = CGSize(
            width: drag.translation.width + drag.velocity.width * Self.projectionFactor,
            height: drag.translation.height + drag.velocity.height * Self.projectionFactor
        )

        // Heading up, or nowhere. A card only leaves downward, so a drag that
        // was thrown back up restores however far it had travelled first.
        guard projected.height > 0 else { return .restore }

        // Heading mostly sideways: a swipe that drifted, not a dismissal.
        guard projected.height >= abs(projected.width) * verticalDominance else { return .restore }

        let travel = travelDistance(inContainerOfHeight: containerHeight)
        return projected.height / travel >= commitProgress ? .dismiss : .restore
    }

    // MARK: - Geometry

    /// The distance that counts as a complete dismissal in this container.
    ///
    /// `package` rather than private because it is the unit every number above
    /// is expressed in: a test that hardcoded "a quarter of 874" would be
    /// asserting the default configuration rather than the behaviour.
    package func travelDistance(inContainerOfHeight height: CGFloat) -> CGFloat {
        max(height * travelFraction, minimumTravel)
    }

    // MARK: - Private

    /// `UIScrollView`'s overscroll curve: displacement that grows ever more
    /// slowly and never reaches `dimension`.
    ///
    /// The asymptote is the property worth having. A linear resistance factor —
    /// "move a third as far" — still lets a long drag fling the card off the
    /// top of the screen; this cannot, whatever the distance dragged, so the
    /// card stays reachable and the gesture stays reversible.
    ///
    /// `dimension` is the travel distance rather than the container's height,
    /// so resistance is measured in the same unit as progress: pulling up as
    /// hard as possible moves the card exactly as far as dragging it down to a
    /// dismissal would have, and no further.
    private static func rubberBand(_ distance: CGFloat, dimension: CGFloat) -> CGFloat {
        guard distance > 0, dimension > 0 else { return 0 }
        return (1 - (1 / (distance * Self.rubberBandCoefficient / dimension + 1))) * dimension
    }
}
