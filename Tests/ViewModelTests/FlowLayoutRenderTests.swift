import CoreGraphics
import SwiftUI
import Testing
@testable import Features

// MARK: - Helpers

/// Half a point: below anything a reader could see, above the rounding a real
/// layout pass does on a 3x screen.
private func isClose(_ lhs: CGFloat, _ rhs: CGFloat, within tolerance: CGFloat = 0.5) -> Bool {
    abs(lhs - rhs) <= tolerance
}

private func isClose(_ frame: CGRect, _ expected: CGRect) -> Bool {
    isClose(frame.minX, expected.minX)
        && isClose(frame.minY, expected.minY)
        && isClose(frame.width, expected.width)
        && isClose(frame.height, expected.height)
}

private let probeItems = (0..<3).map { FlowProbeItem(id: $0, width: 100, height: 40) }

// MARK: - Suite

/// Phase 10 item 4, the half that needs SwiftUI.
///
/// `FlowLayoutEngineTests` owns the arithmetic, and it owns it precisely
/// because `LayoutSubviews` cannot be constructed: there is no way to call
/// `sizeThatFits` or `placeSubviews` outside a tree the framework is driving.
/// What that leaves — and what is here — is the wiring. A `Layout` that
/// measured at the wrong proposal, forgot to offset by `bounds.origin`, or
/// placed its subviews at a size other than the one it broke lines with would
/// pass every test in that file and still draw the wrong thing, because none
/// of those three mistakes is in the arithmetic.
@Suite("FlowLayout in a rendered tree", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct FlowLayoutRenderTests {

    @Test("Three chips in a 250-point container land on two lines where the engine says")
    func chipsArePlacedWhereTheEngineSays() async {
        let recorder = FlowFrameRecorder()
        let harness = await RenderHarness.mount(
            FlowProbeHarness(
                items: probeItems,
                containerWidth: 250,
                spacing: 8,
                lineSpacing: 10,
                recorder: recorder
            )
        )
        defer { harness.dismount() }

        await settleUntil(harness) { recorder.framesInFlowSpace(count: probeItems.count) != nil }

        guard let frames = recorder.framesInFlowSpace(count: probeItems.count) else {
            Issue.record("The flow never reported a frame for all three items")
            return
        }

        #expect(isClose(frames[0], CGRect(x: 0, y: 0, width: 100, height: 40)))
        #expect(isClose(frames[1], CGRect(x: 108, y: 0, width: 100, height: 40)))
        #expect(isClose(frames[2], CGRect(x: 0, y: 50, width: 100, height: 40)))
    }

    /// The size half of the same pass. A flow that placed correctly but
    /// reported the width it was proposed rather than the width it used would
    /// leave the trailing gap inside its own bounds, which nothing about the
    /// frames above would notice.
    @Test("The flow reports the width it used and the height its lines add up to")
    func theFlowReportsTheSizeItActuallyUsed() async {
        let recorder = FlowFrameRecorder()
        let harness = await RenderHarness.mount(
            FlowProbeHarness(
                items: probeItems,
                containerWidth: 250,
                spacing: 8,
                lineSpacing: 10,
                recorder: recorder
            )
        )
        defer { harness.dismount() }

        await settleUntil(harness) { recorder.flowFrame != .zero }

        #expect(isClose(recorder.flowFrame.width, 208))
        #expect(isClose(recorder.flowFrame.height, 90))
    }

    /// A flow cannot narrow a chip, so an item wider than the container keeps
    /// its width and the flow says so. The alternative — reporting the
    /// container's width — is how a custom layout ends up drawing outside its
    /// own bounds with nothing in the API to say it has.
    @Test("An item wider than the container is reported as overflow, not truncated")
    func anOverWideItemKeepsItsWidth() async {
        let recorder = FlowFrameRecorder()
        let wide = [FlowProbeItem(id: 0, width: 300, height: 40)]
        let harness = await RenderHarness.mount(
            FlowProbeHarness(items: wide, containerWidth: 200, spacing: 8, lineSpacing: 10, recorder: recorder)
        )
        defer { harness.dismount() }

        await settleUntil(harness) { recorder.framesInFlowSpace(count: 1) != nil }

        #expect(isClose(recorder.flowFrame.width, 300))
        #expect(isClose(recorder.framesInFlowSpace(count: 1)?.first?.width ?? 0, 300))
    }

    /// The property the component exists for, and the one no static assertion
    /// can make: narrowing the container moves items between lines, because
    /// the line breaking is redone against measurements the cache kept and a
    /// width it did not.
    @Test("Narrowing the container reflows the items onto new lines")
    func narrowingTheContainerReflows() async {
        let recorder = FlowFrameRecorder()
        let driver = FlowWidthDriver(width: 250)
        let harness = await RenderHarness.mount(
            FlowReflowHarness(items: probeItems, driver: driver, recorder: recorder)
        )
        defer { harness.dismount() }

        await settleUntil(harness) { recorder.framesInFlowSpace(count: probeItems.count) != nil }
        #expect(isClose(recorder.framesInFlowSpace(count: 3)?[1].minX ?? 0, 108))

        driver.width = 120
        await settleUntil(harness) {
            isClose(recorder.framesInFlowSpace(count: 3)?[1].minX ?? -1, 0)
        }

        guard let frames = recorder.framesInFlowSpace(count: probeItems.count) else {
            Issue.record("The flow stopped reporting frames after the container narrowed")
            return
        }

        #expect(isClose(frames[0], CGRect(x: 0, y: 0, width: 100, height: 40)))
        #expect(isClose(frames[1], CGRect(x: 0, y: 50, width: 100, height: 40)))
        #expect(isClose(frames[2], CGRect(x: 0, y: 100, width: 100, height: 40)))
    }

    /// Phase 10 item 7's right-to-left half, and the test that settled it.
    ///
    /// The question a custom `Layout` raises is whether SwiftUI mirrors its
    /// placement for a right-to-left reader or leaves that to the layout. The
    /// two answers demand opposite implementations, both look correct in the
    /// source, and the difference is visible only in a language none of the
    /// previews are written in — so this measures it rather than assuming.
    ///
    /// The answer is that **the framework mirrors**, which WWDC22's *Compose
    /// custom layouts with SwiftUI* states outright: "the framework
    /// automatically flips the x position of each view when laying out views
    /// in that direction". The engine below is therefore left-to-right
    /// arithmetic with no direction in it at all, and this test is what would
    /// fail if somebody added a mirror to it — a flow flipped twice reads
    /// left-to-right in Arabic, which is the defect such a mirror would be
    /// trying to prevent.
    ///
    /// This suite has now caught that in both directions: the mirror went in
    /// first, on the assumption that the framework did nothing, and these
    /// three expectations are what said otherwise.
    @Test("A right-to-left reader gets the first chip at the trailing edge")
    func rightToLeftMirrorsTheFlow() async {
        let recorder = FlowFrameRecorder()
        let harness = await RenderHarness.mount(
            FlowProbeHarness(
                items: probeItems,
                containerWidth: 250,
                spacing: 8,
                lineSpacing: 10,
                recorder: recorder,
                layoutDirection: .rightToLeft
            )
        )
        defer { harness.dismount() }

        await settleUntil(harness) { recorder.framesInFlowSpace(count: probeItems.count) != nil }

        guard let frames = recorder.framesInFlowSpace(count: probeItems.count) else {
            Issue.record("The flow never reported a frame for all three items")
            return
        }

        // The mirror image of the left-to-right case above — 0, 108, 0 becomes
        // 108, 0, 108 about a flow 208 points wide — and every one of those
        // numbers is the framework's doing, not the engine's.
        #expect(isClose(frames[0], CGRect(x: 108, y: 0, width: 100, height: 40)))
        #expect(isClose(frames[1], CGRect(x: 0, y: 0, width: 100, height: 40)))
        #expect(isClose(frames[2], CGRect(x: 108, y: 50, width: 100, height: 40)))
    }
}
