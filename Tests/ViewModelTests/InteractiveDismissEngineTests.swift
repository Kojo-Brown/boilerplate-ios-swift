import CoreGraphics
import Testing
@testable import Features

// MARK: - Fixtures

/// A container tall enough to be realistic and round enough to do arithmetic
/// with: at the default quarter-fraction its travel distance is exactly 200
/// points, and the default commit threshold exactly 80.
private let containerHeight: CGFloat = 800

private let engine = InteractiveDismissEngine()

private func drag(_ width: CGFloat, _ height: CGFloat, velocity: CGSize = .zero) -> InteractiveDismissEngine.Drag {
    InteractiveDismissEngine.Drag(
        translation: CGSize(width: width, height: height),
        velocity: velocity
    )
}

private func isClose(_ lhs: CGFloat, _ rhs: CGFloat, within tolerance: CGFloat = 0.001) -> Bool {
    abs(lhs - rhs) <= tolerance
}

// MARK: - Transform

/// Phase 10 item 5. What the card wears while a finger is on it, tested as
/// values in and values out.
///
/// None of this is reachable through the view. `DragGesture.Value` has no
/// initialiser, so a test that wanted to assert "a flick of 1,200 points a
/// second dismisses" through `InteractiveDismissLayer` would have to synthesise
/// touches into a hosted window and hope the gesture recogniser agreed — which
/// measures UIKit's velocity smoothing rather than this repo's threshold. The
/// engine is the half worth freezing, and it freezes here.
@Suite("Interactive dismissal — the transform under the finger")
struct InteractiveDismissTransformTests {

    /// The property that is invisible in a screenshot and obvious in the hand:
    /// a card nobody is touching is exactly where it was put.
    @Test("At rest the transform is the identity")
    func atRestTheTransformIsTheIdentity() {
        #expect(engine.transform(forTranslation: .zero, containerHeight: containerHeight) == .identity)
    }

    @Test("Downward movement follows the finger one to one")
    func downwardMovementFollowsTheFinger() {
        let transform = engine.transform(
            forTranslation: CGSize(width: 0, height: 100),
            containerHeight: containerHeight
        )

        #expect(isClose(transform.offset.height, 100))
        #expect(isClose(transform.progress, 0.5))
    }

    @Test("Horizontal movement follows the finger and counts for nothing")
    func horizontalMovementCountsForNothing() {
        let sideways = engine.transform(
            forTranslation: CGSize(width: 120, height: 0),
            containerHeight: containerHeight
        )

        #expect(isClose(sideways.offset.width, 120))
        #expect(isClose(sideways.progress, 0))
        #expect(isClose(sideways.scale, 1))
    }

    @Test("Progress reaches 1 at the travel distance and stops there")
    func progressSaturatesAtTheTravelDistance() {
        let atTravel = engine.transform(
            forTranslation: CGSize(width: 0, height: 200),
            containerHeight: containerHeight
        )
        let wellPast = engine.transform(
            forTranslation: CGSize(width: 0, height: 900),
            containerHeight: containerHeight
        )

        #expect(isClose(atTravel.progress, 1))
        #expect(isClose(wellPast.progress, 1))

        // Saturated progress is not a stuck card: it keeps tracking the finger
        // so the gesture stays continuous all the way off the screen.
        #expect(isClose(wellPast.offset.height, 900))
    }

    @Test("Scale shrinks to the floor and no further")
    func scaleShrinksToTheFloorAndNoFurther() {
        let half = engine.transform(
            forTranslation: CGSize(width: 0, height: 100),
            containerHeight: containerHeight
        )
        let past = engine.transform(
            forTranslation: CGSize(width: 0, height: 900),
            containerHeight: containerHeight
        )

        #expect(isClose(half.scale, 1 - (1 - engine.scaleFloor) * 0.5))
        #expect(isClose(past.scale, engine.scaleFloor))
    }

    @Test("The backdrop fades out in step with progress")
    func theBackdropFadesWithProgress() {
        for height in stride(from: CGFloat(0), through: 200, by: 25) {
            let transform = engine.transform(
                forTranslation: CGSize(width: 0, height: height),
                containerHeight: containerHeight
            )
            #expect(isClose(transform.backdropOpacity, 1 - transform.progress))
        }
    }

    /// The reason the curve is `UIScrollView`'s rather than a resistance
    /// factor: a factor still lets a long drag throw the card off the top of
    /// the screen, where an asymptote cannot.
    @Test("Upward movement resists and can never exceed the travel distance")
    func upwardMovementResistsAndIsBounded() {
        let modest = engine.transform(
            forTranslation: CGSize(width: 0, height: -200),
            containerHeight: containerHeight
        )
        let absurd = engine.transform(
            forTranslation: CGSize(width: 0, height: -10_000),
            containerHeight: containerHeight
        )
        let travel = engine.travelDistance(inContainerOfHeight: containerHeight)

        #expect(modest.offset.height < 0)
        #expect(modest.offset.height > -200)
        #expect(absurd.offset.height > -travel)
        #expect(modest.progress == 0)
        #expect(absurd.progress == 0)
    }

    /// Continuity, checked across the seam where the rubber band meets
    /// one-to-one tracking. A discontinuity at zero is a card that jumps under
    /// the finger the moment a drag changes direction.
    @Test("Offset and progress are monotone in the drag")
    func theTransformIsMonotone() {
        var previousOffset = -CGFloat.infinity
        var previousProgress = -CGFloat.infinity

        for height in stride(from: CGFloat(-300), through: 500, by: 5) {
            let transform = engine.transform(
                forTranslation: CGSize(width: 0, height: height),
                containerHeight: containerHeight
            )
            #expect(transform.offset.height > previousOffset)
            #expect(transform.progress >= previousProgress)
            previousOffset = transform.offset.height
            previousProgress = transform.progress
        }
    }

    /// A hosting controller that has not been sized yet reports a height of
    /// zero, and a threshold derived from it would make the very first twitch a
    /// complete dismissal — after dividing by zero to get there.
    @Test("A container with no height falls back to the minimum travel")
    func anUnmeasuredContainerFallsBackToTheMinimum() {
        #expect(isClose(engine.travelDistance(inContainerOfHeight: 0), engine.minimumTravel))
        #expect(isClose(engine.travelDistance(inContainerOfHeight: containerHeight), 200))

        let transform = engine.transform(forTranslation: CGSize(width: 0, height: 22), containerHeight: 0)
        #expect(transform.progress < 1)
    }
}

// MARK: - Resolution

@Suite("Interactive dismissal — what happens when the finger lifts")
struct InteractiveDismissResolutionTests {

    @Test("A drag that went nowhere restores")
    func aDragThatWentNowhereRestores() {
        #expect(engine.resolution(for: drag(0, 0), containerHeight: containerHeight) == .restore)
    }

    @Test("A slow drag short of the commit point restores")
    func aShortSlowDragRestores() {
        #expect(engine.resolution(for: drag(0, 60), containerHeight: containerHeight) == .restore)
    }

    @Test("A slow drag past the commit point dismisses")
    func aLongSlowDragDismisses() {
        #expect(engine.resolution(for: drag(0, 100), containerHeight: containerHeight) == .dismiss)
    }

    /// The whole reason release velocity is read at all. Both of these drags
    /// stopped forty points down; one of them was still travelling.
    @Test("A flick dismisses from a distance that would otherwise restore")
    func aFlickDismissesFromAShortDistance() {
        let stopped = drag(0, 40)
        let flicked = drag(0, 40, velocity: CGSize(width: 0, height: 800))

        #expect(engine.resolution(for: stopped, containerHeight: containerHeight) == .restore)
        #expect(engine.resolution(for: flicked, containerHeight: containerHeight) == .dismiss)
    }

    /// The other half of reading velocity, and the half that is easy to forget:
    /// a card dragged well past the threshold and then thrown back up was put
    /// back, and dismissing it is the opposite of what the hand just did.
    @Test("A drag thrown back upward restores however far it had travelled")
    func aDragThrownBackUpwardRestores() {
        let returned = drag(0, 120, velocity: CGSize(width: 0, height: -2000))

        #expect(engine.resolution(for: drag(0, 120), containerHeight: containerHeight) == .dismiss)
        #expect(engine.resolution(for: returned, containerHeight: containerHeight) == .restore)
    }

    /// The most annoying false positive a hero card can produce: a back swipe
    /// or a page turn that drifted down far enough to cross the threshold.
    @Test("A mostly sideways drag does not dismiss, however far down it drifted")
    func aSidewaysDragDoesNotDismiss() {
        #expect(engine.resolution(for: drag(400, 120), containerHeight: containerHeight) == .restore)
        #expect(engine.resolution(for: drag(100, 120), containerHeight: containerHeight) == .dismiss)
        #expect(engine.resolution(for: drag(0, 120), containerHeight: containerHeight) == .dismiss)
    }

    @Test("A sideways flick does not dismiss either")
    func aSidewaysFlickDoesNotDismiss() {
        let thrownAcross = drag(0, 30, velocity: CGSize(width: 2000, height: 200))
        #expect(engine.resolution(for: thrownAcross, containerHeight: containerHeight) == .restore)
    }

    /// The threshold is configuration, not a constant folded into the
    /// arithmetic — the same drag has to change its answer when the engine is
    /// asked for a stickier card.
    @Test("Raising the commit point changes the answer for the same drag")
    func raisingTheCommitPointChangesTheAnswer() {
        let sticky = InteractiveDismissEngine(commitProgress: 0.8)
        let gesture = drag(0, 100)

        #expect(engine.resolution(for: gesture, containerHeight: containerHeight) == .dismiss)
        #expect(sticky.resolution(for: gesture, containerHeight: containerHeight) == .restore)
    }

    /// The threshold is a fraction of the container, so the same gesture means
    /// the same thing on a phone and on an iPad — which a fixed point count
    /// cannot do.
    @Test("The same drag resolves differently in containers of different heights")
    func theThresholdScalesWithTheContainer() {
        let gesture = drag(0, 100)

        #expect(engine.resolution(for: gesture, containerHeight: 600) == .dismiss)
        #expect(engine.resolution(for: gesture, containerHeight: 1400) == .restore)
    }

    /// The clamps in the initialiser are load-bearing rather than defensive
    /// decoration: a zero minimum travel is a division by zero one unmeasured
    /// container away.
    @Test("A minimum travel of zero is clamped rather than divided by")
    func aZeroMinimumTravelIsClamped() {
        let degenerate = InteractiveDismissEngine(minimumTravel: 0)

        #expect(degenerate.minimumTravel >= 1)
        #expect(degenerate.travelDistance(inContainerOfHeight: 0) >= 1)
        #expect(degenerate.transform(forTranslation: .zero, containerHeight: 0) == .identity)
    }
}
