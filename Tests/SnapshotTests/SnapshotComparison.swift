import Foundation

// MARK: - Tolerance

/// How far two snapshots may drift apart before the gate calls it a failure.
///
/// Two knobs rather than one, because the two kinds of drift are not the same
/// thing. A handful of pixels on the edge of a glyph moving by a couple of
/// values is the encoder, the renderer's antialiasing, or a simulator runtime
/// that nudged a font's hinting — nothing a reader would see. A string, a
/// colour, a corner radius or a layout changing moves *many* pixels, and
/// usually moves them a long way.
///
/// So ``channelTolerance`` decides what counts as a differing pixel at all, and
/// ``mismatchBudget`` decides how many of them the image is allowed to have.
/// Neither is a precision the gate claims to have measured: they start tight,
/// and ``SnapshotGateTests`` prints the observed numbers whenever a comparison
/// is not exact, so that moving one of them is a decision taken against
/// evidence from a real run rather than a shrug. `docs/snapshot-testing.md`
/// records what they have been moved to and why.
struct SnapshotTolerance: Equatable, Sendable {

    /// The per-channel difference, 0…255, at or below which two pixels are the
    /// same pixel.
    let channelTolerance: UInt8

    /// The fraction of an image's pixels, 0…1, allowed to exceed
    /// ``channelTolerance``.
    let mismatchBudget: Double

    /// What the gate runs with.
    static let standard = SnapshotTolerance(channelTolerance: 4, mismatchBudget: 0.001)

    /// No drift at all, which is what the record lane holds a PNG round trip to.
    static let exact = SnapshotTolerance(channelTolerance: 0, mismatchBudget: 0)
}

// MARK: - Difference

/// What two comparable snapshots disagree about, in numbers.
struct SnapshotDifference: Equatable, Sendable, CustomStringConvertible {

    let extent: SnapshotExtent
    let mismatchedPixels: Int
    let maxChannelDelta: Int

    /// The box the mismatched pixels fall inside, or `nil` when there are none.
    let region: SnapshotRegion?

    /// The mismatched share of the image, 0…1.
    var fraction: Double {
        guard extent.pixelCount > 0 else { return 0 }
        return Double(mismatchedPixels) / Double(extent.pixelCount)
    }

    var isExact: Bool { maxChannelDelta == 0 }

    var description: String {
        guard let region else {
            return "no differing pixels in \(extent) (largest channel delta \(maxChannelDelta))"
        }
        let percent = String(format: "%.4f%%", fraction * 100)
        return """
            \(mismatchedPixels) of \(extent.pixelCount) pixels differ (\(percent)), \
            largest channel delta \(maxChannelDelta), confined to \(region)
            """
    }
}

// MARK: - Comparison

/// The verdict on one snapshot.
enum SnapshotComparison: Equatable, Sendable, CustomStringConvertible {

    /// The two images are the same size and agree within the tolerance.
    case matches(SnapshotDifference)

    /// The two images are the same size and do not agree.
    case differs(SnapshotDifference)

    /// The view no longer renders at the size it was recorded at.
    ///
    /// Reported separately because there is nothing to diff: the images cannot
    /// be laid over each other, and the size is itself the finding. A view that
    /// gained a line of text, lost a padding, or stopped honouring a dynamic
    /// type size arrives here, and the two numbers say so directly.
    case extentChanged(expected: SnapshotExtent, actual: SnapshotExtent)

    var passes: Bool {
        if case .matches = self { return true }
        return false
    }

    var difference: SnapshotDifference? {
        switch self {
        case let .matches(difference), let .differs(difference): return difference
        case .extentChanged: return nil
        }
    }

    var description: String {
        switch self {
        case let .matches(difference):
            return "matches: \(difference)"
        case let .differs(difference):
            return "differs: \(difference)"
        case let .extentChanged(expected, actual):
            return "size changed: recorded at \(expected), rendered at \(actual)"
        }
    }
}

extension SnapshotComparison {

    /// Compares two snapshots pixel by pixel.
    init(expected: SnapshotBitmap, actual: SnapshotBitmap, tolerance: SnapshotTolerance) {
        guard expected.extent == actual.extent else {
            self = .extentChanged(expected: expected.extent, actual: actual.extent)
            return
        }

        let limit = Int(tolerance.channelTolerance)
        let channels = SnapshotBitmap.channelsPerPixel
        let width = expected.extent.width
        var mismatched = 0
        var maxDelta = 0
        var region: SnapshotRegion?

        expected.pixels.withUnsafeBufferPointer { recorded in
            actual.pixels.withUnsafeBufferPointer { rendered in
                for offset in stride(from: 0, to: recorded.count, by: channels) {
                    var delta = 0
                    for channel in 0 ..< channels {
                        let difference = Int(recorded[offset + channel]) - Int(rendered[offset + channel])
                        delta = max(delta, abs(difference))
                    }
                    maxDelta = max(maxDelta, delta)
                    guard delta > limit else { continue }
                    mismatched += 1
                    let index = offset / channels
                    if region == nil {
                        region = SnapshotRegion(x: index % width, y: index / width)
                    } else {
                        region?.extend(x: index % width, y: index / width)
                    }
                }
            }
        }

        let difference = SnapshotDifference(
            extent: expected.extent,
            mismatchedPixels: mismatched,
            maxChannelDelta: maxDelta,
            region: region
        )
        self = difference.fraction > tolerance.mismatchBudget ? .differs(difference) : .matches(difference)
    }
}

// MARK: - Diff image

extension SnapshotBitmap {

    /// The recorded image with every differing pixel painted over in magenta.
    ///
    /// Magenta because no colour in this design system is anywhere near it, and
    /// over the *recorded* image rather than beside it because the question a
    /// reader has is "what moved", which is answered by one picture and not by
    /// two. The unchanged pixels are faded halfway to white so that the marks
    /// read against dark surfaces as well as light ones.
    ///
    /// `nil` when the two cannot be overlaid at all, which is the case the
    /// comparison reports as a changed extent.
    static func difference(
        expected: SnapshotBitmap,
        actual: SnapshotBitmap,
        tolerance: SnapshotTolerance
    ) -> SnapshotBitmap? {
        guard expected.extent == actual.extent else { return nil }

        let limit = Int(tolerance.channelTolerance)
        let channels = channelsPerPixel
        var painted = expected.pixels

        for offset in stride(from: 0, to: painted.count, by: channels) {
            var delta = 0
            for channel in 0 ..< channels {
                let difference = Int(expected.pixels[offset + channel]) - Int(actual.pixels[offset + channel])
                delta = max(delta, abs(difference))
            }
            if delta > limit {
                painted[offset] = 255
                painted[offset + 1] = 0
                painted[offset + 2] = 255
                painted[offset + 3] = 255
            } else {
                for channel in 0 ..< 3 {
                    let faded = (Int(painted[offset + channel]) + 255) / 2
                    painted[offset + channel] = UInt8(faded)
                }
            }
        }

        return SnapshotBitmap(extent: expected.extent, pixels: painted)
    }
}
