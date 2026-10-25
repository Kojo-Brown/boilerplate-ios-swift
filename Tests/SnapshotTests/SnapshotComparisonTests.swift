import Foundation
import Testing

// MARK: - The engine under the gate

/// The half of a snapshot gate that can be tested without a picture.
///
/// Everything in ``SnapshotGateTests`` depends on a renderer, a simulator and
/// fifteen committed PNGs, and none of it can say whether the comparison it
/// trusts is right. These cases can: they build bitmaps by hand, so the
/// expected answer is arithmetic rather than a recording, and they are the
/// reason a tolerance, a mismatch budget and a bounding box are claims rather
/// than hopes.
///
/// The round-trip cases are not padding. A bitmap goes through two conversions
/// nobody looks at — into a `CGImage` and into a PNG — and a vertical flip or
/// a premultiplication rounding error in either one is invisible in a golden
/// (the recording and the comparison would both be wrong the same way) and
/// fatal to the gate's meaning.
@Suite("Snapshot comparison engine")
struct SnapshotComparisonTests {

    // MARK: - Agreement

    @Test("A bitmap compared with itself matches exactly")
    func identicalBitmapsMatch() {
        let bitmap = grey(128, extent: SnapshotExtent(width: 8, height: 8))
        let comparison = SnapshotComparison(expected: bitmap, actual: bitmap, tolerance: .standard)

        #expect(comparison.passes)
        #expect(comparison.difference?.isExact == true)
        #expect(comparison.difference?.mismatchedPixels == 0)
        #expect(comparison.difference?.region == nil)
    }

    @Test("A channel inside the tolerance is not a differing pixel, but is still reported")
    func driftInsideToleranceMatches() {
        let extent = SnapshotExtent(width: 8, height: 8)
        let expected = grey(128, extent: extent)
        let actual = changing(expected, at: 3, 4, to: 131)
        let comparison = SnapshotComparison(expected: expected, actual: actual, tolerance: .standard)

        #expect(comparison.passes)
        #expect(comparison.difference?.mismatchedPixels == 0)
        #expect(comparison.difference?.maxChannelDelta == 3)
        #expect(comparison.difference?.isExact == false)
    }

    @Test("One differing pixel in a large image is inside the mismatch budget")
    func oneDifferingPixelIsWithinBudget() {
        let extent = SnapshotExtent(width: 50, height: 40)
        let expected = grey(10, extent: extent)
        let actual = changing(expected, at: 10, 10, to: 200)
        let comparison = SnapshotComparison(expected: expected, actual: actual, tolerance: .standard)

        #expect(comparison.passes)
        #expect(comparison.difference?.mismatchedPixels == 1)
        #expect(comparison.difference?.fraction == 0.0005)
    }

    // MARK: - Disagreement

    @Test("Enough differing pixels to leave the budget is a failure")
    func threeDifferingPixelsExceedBudget() {
        let extent = SnapshotExtent(width: 50, height: 40)
        let expected = grey(10, extent: extent)
        var actual = changing(expected, at: 10, 10, to: 200)
        actual = changing(actual, at: 11, 10, to: 200)
        actual = changing(actual, at: 12, 10, to: 200)
        let comparison = SnapshotComparison(expected: expected, actual: actual, tolerance: .standard)

        #expect(!comparison.passes)
        #expect(comparison.difference?.mismatchedPixels == 3)
    }

    @Test("The exact tolerance fails on a single value of drift")
    func exactToleranceRejectsAnyDrift() {
        let extent = SnapshotExtent(width: 4, height: 4)
        let expected = grey(10, extent: extent)
        let actual = changing(expected, at: 0, 0, to: 11)
        let comparison = SnapshotComparison(expected: expected, actual: actual, tolerance: .exact)

        #expect(!comparison.passes)
        #expect(comparison.difference?.maxChannelDelta == 1)
    }

    @Test("A size change is reported as a size change rather than a diff")
    func differentExtentsReportTheSizes() {
        let expected = grey(10, extent: SnapshotExtent(width: 8, height: 8))
        let actual = grey(10, extent: SnapshotExtent(width: 8, height: 9))
        let comparison = SnapshotComparison(expected: expected, actual: actual, tolerance: .standard)

        #expect(!comparison.passes)
        #expect(comparison.difference == nil)
        #expect(comparison == .extentChanged(expected: expected.extent, actual: actual.extent))
    }

    // MARK: - Where it moved

    @Test("The reported region is the bounding box of the differing pixels")
    func regionBoundsTheDifference() throws {
        let extent = SnapshotExtent(width: 10, height: 10)
        let expected = grey(10, extent: extent)
        var actual = changing(expected, at: 1, 1, to: 250)
        actual = changing(actual, at: 3, 2, to: 250)
        let comparison = SnapshotComparison(expected: expected, actual: actual, tolerance: .standard)
        let region = try #require(comparison.difference?.region)

        var expectedRegion = SnapshotRegion(x: 1, y: 1)
        expectedRegion.extend(x: 3, y: 2)

        #expect(region == expectedRegion)
        #expect(region.width == 3)
        #expect(region.height == 2)
    }

    @Test("The overlay paints the differing pixels and fades the rest")
    func overlayMarksOnlyWhatMoved() throws {
        let extent = SnapshotExtent(width: 4, height: 4)
        let expected = grey(0, extent: extent)
        let actual = changing(expected, at: 2, 1, to: 250)
        let overlay = try #require(
            SnapshotBitmap.difference(expected: expected, actual: actual, tolerance: .standard)
        )

        #expect(overlay.pixel(x: 2, y: 1) == [255, 0, 255, 255])
        #expect(overlay.pixel(x: 0, y: 0) == [127, 127, 127, 255])
    }

    @Test("Nothing to overlay when the two cannot be laid over each other")
    func overlayNeedsMatchingExtents() {
        let expected = grey(0, extent: SnapshotExtent(width: 4, height: 4))
        let actual = grey(0, extent: SnapshotExtent(width: 4, height: 5))

        #expect(
            SnapshotBitmap.difference(expected: expected, actual: actual, tolerance: .standard) == nil
        )
    }

    // MARK: - Round trips

    @Test("A bitmap survives a CGImage round trip the right way up")
    func cgImageRoundTripKeepsOrientation() throws {
        let original = gradient(extent: SnapshotExtent(width: 5, height: 3))
        let image = try #require(original.cgImage)
        let returned = try #require(SnapshotBitmap(image))

        #expect(returned.extent == original.extent)
        #expect(returned == original)
        // Stated separately from the equality above, because this is the byte
        // a vertical flip would move: the top-left pixel's green channel is
        // its row index, and the bottom-left row's is 2.
        #expect(returned.pixel(x: 0, y: 0) == [0, 0, 0, 255])
        #expect(returned.pixel(x: 0, y: 2) == [0, 2, 2, 255])
    }

    @Test("An opaque bitmap survives a PNG round trip byte for byte")
    func pngRoundTripIsLossless() throws {
        let original = gradient(extent: SnapshotExtent(width: 6, height: 4))
        let data = try #require(original.pngData())
        let returned = try #require(SnapshotBitmap.decoding(pngData: data))

        #expect(returned == original)
    }

    @Test("Something that is not a PNG decodes to nothing rather than to an empty image")
    func garbageIsNotADecodedSnapshot() {
        #expect(SnapshotBitmap.decoding(pngData: Data([0x00, 0x01, 0x02, 0x03])) == nil)
    }

    // MARK: - Fixtures

    private func grey(_ value: UInt8, extent: SnapshotExtent) -> SnapshotBitmap {
        let pixel: [UInt8] = [value, value, value, 255]
        var pixels: [UInt8] = []
        pixels.reserveCapacity(extent.pixelCount * SnapshotBitmap.channelsPerPixel)
        for _ in 0 ..< extent.pixelCount {
            pixels.append(contentsOf: pixel)
        }
        return SnapshotBitmap(extent: extent, pixels: pixels)
    }

    /// Deliberately asymmetric in both directions, so that a flip or a
    /// transpose anywhere in a conversion changes the bytes.
    private func gradient(extent: SnapshotExtent) -> SnapshotBitmap {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(extent.pixelCount * SnapshotBitmap.channelsPerPixel)
        for y in 0 ..< extent.height {
            for x in 0 ..< extent.width {
                pixels.append(contentsOf: [UInt8(x), UInt8(y), UInt8(x + y), 255])
            }
        }
        return SnapshotBitmap(extent: extent, pixels: pixels)
    }

    /// The same bitmap with one pixel's red channel changed.
    private func changing(
        _ bitmap: SnapshotBitmap,
        at x: Int,
        _ y: Int,
        to value: UInt8
    ) -> SnapshotBitmap {
        var pixels = bitmap.pixels
        pixels[(y * bitmap.extent.width + x) * SnapshotBitmap.channelsPerPixel] = value
        return SnapshotBitmap(extent: bitmap.extent, pixels: pixels)
    }
}
