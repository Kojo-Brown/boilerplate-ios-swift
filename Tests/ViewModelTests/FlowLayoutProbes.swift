import CoreGraphics
import SwiftUI
@testable import Features

// MARK: - Preferences

/// Where each probed subview ended up, in window coordinates, keyed by its
/// position in the flow.
///
/// Window coordinates rather than a named coordinate space on purpose: naming
/// one would mean `coordinateSpace(name:)`, which iOS 17 deprecated, and this
/// package's CI fails a build that emits any warning at all. The flow reports
/// its own frame through ``FlowFramePreference`` below, so the test subtracts
/// one from the other and gets the same numbers without the deprecation.
struct FlowItemFramePreference: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, newer in newer }
    }
}

/// The flow's own frame: its origin is what item frames are measured against,
/// and its size is `sizeThatFits`'s answer read back out of a rendered tree
/// rather than called directly.
struct FlowFramePreference: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

// MARK: - Recorder

/// What the probes write into and the test reads out of.
///
/// Main-actor isolated, which also makes it `Sendable`: that is what lets it
/// be captured by `onPreferenceChange`, whose action is `@Sendable` in the
/// current SDK and was not in the previous one. The writes go through
/// `MainActor.assumeIsolated` because SwiftUI delivers preference changes on
/// the main thread while the closure's own signature no longer says so.
@MainActor
final class FlowFrameRecorder {
    var itemFrames: [Int: CGRect] = [:]
    var flowFrame: CGRect = .zero

    init() {}

    /// The item frames in flow order and relative to the flow's own origin, or
    /// `nil` while any of `count` has yet to report.
    ///
    /// The optional is the difference between "the layout put them here" and
    /// "the test looked too early", and a suite that polls until this is
    /// non-`nil` cannot mistake the second for the first.
    func framesInFlowSpace(count: Int) -> [CGRect]? {
        guard flowFrame != .zero else { return nil }
        let ordered = (0..<count).compactMap { itemFrames[$0] }
        guard ordered.count == count else { return nil }
        return ordered.map { $0.offsetBy(dx: -flowFrame.minX, dy: -flowFrame.minY) }
    }
}

// MARK: - Harness

/// One probed item: a fixed-size rectangle standing in for a chip.
///
/// Fixed rather than text, because a `Text`'s width depends on the font the
/// simulator resolves, and an assertion on an exact origin should not move
/// with a system font metric.
struct FlowProbeItem: Identifiable, Equatable {
    let id: Int
    let width: CGFloat
    let height: CGFloat
}

/// A ``FlowLayout`` of fixed-size items, reporting every frame it produces.
///
/// This is the only part of the flow's coverage that needs a simulator, and it
/// is deliberately the narrow part: *which* line an item belongs on is settled
/// by `FlowLayoutEngineTests`, so what is left here is whether the `Layout`
/// conformance measures the subviews it was handed, offsets the engine's
/// frames by its own bounds, and reports the size it actually used.
struct FlowProbeHarness: View {
    let items: [FlowProbeItem]
    let containerWidth: CGFloat
    let spacing: CGFloat
    let lineSpacing: CGFloat
    let recorder: FlowFrameRecorder

    var body: some View {
        FlowLayout(lineAlignment: .top, spacing: spacing, lineSpacing: lineSpacing) {
            ForEach(items) { item in
                Color.clear
                    .frame(width: item.width, height: item.height)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: FlowItemFramePreference.self,
                                value: [item.id: proxy.frame(in: .global)]
                            )
                        }
                    }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: FlowFramePreference.self, value: proxy.frame(in: .global))
            }
        }
        .frame(width: containerWidth, alignment: .leading)
        .onPreferenceChange(FlowItemFramePreference.self) { frames in
            MainActor.assumeIsolated { recorder.itemFrames = frames }
        }
        .onPreferenceChange(FlowFramePreference.self) { frame in
            MainActor.assumeIsolated { recorder.flowFrame = frame }
        }
    }
}

// MARK: - Reflow

/// The one thing that changes in the reflow test: how much room the flow has.
@Observable
@MainActor
final class FlowWidthDriver {
    var width: CGFloat

    init(width: CGFloat) {
        self.width = width
    }
}

/// ``FlowProbeHarness`` with its container width under observation, so a test
/// can narrow the flow and watch the items move between lines.
struct FlowReflowHarness: View {
    let items: [FlowProbeItem]
    let driver: FlowWidthDriver
    let recorder: FlowFrameRecorder

    var body: some View {
        FlowProbeHarness(
            items: items,
            containerWidth: driver.width,
            spacing: 8,
            lineSpacing: 10,
            recorder: recorder
        )
    }
}
