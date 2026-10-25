import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Extent

/// The pixel dimensions of a snapshot.
///
/// A type rather than a tuple because it is half of the most common failure
/// this gate reports — a view that grew a line of text changes its height
/// before it changes a single pixel of its first row — and a failure message
/// that can name both sizes is more use than one describing the diff of two
/// images that were never comparable.
struct SnapshotExtent: Equatable, Sendable, CustomStringConvertible {
    var width: Int
    var height: Int

    var pixelCount: Int { width * height }

    var description: String { "\(width)x\(height)px" }
}

// MARK: - Region

/// The bounding box of the pixels two snapshots disagree about.
///
/// This is the line to read first on a failure. "x 14…376, y 52…71" is one row
/// of text and almost always a string or a font change; a box covering the
/// whole image is a layout or colour change; a box a few pixels tall at the
/// bottom edge is something that grew. None of that is visible in a pixel
/// count, and the count is all a bare percentage gives.
struct SnapshotRegion: Equatable, Sendable, CustomStringConvertible {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int

    init(x: Int, y: Int) {
        minX = x
        maxX = x
        minY = y
        maxY = y
    }

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }

    var description: String {
        "x \(minX)…\(maxX), y \(minY)…\(maxY) (\(width)x\(height)px)"
    }

    /// Grows the box so that it holds the given pixel.
    mutating func extend(x: Int, y: Int) {
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
    }
}

// MARK: - Bitmap

/// A decoded image in one fixed layout, so that two of them can be compared
/// without either one's provenance mattering.
///
/// Every bitmap here is 8-bit RGBA, premultiplied, sRGB, row-major, with no row
/// padding — whatever the `CGImage` it came from was. That normalisation is the
/// point of the type: a snapshot rendered this run arrives as whatever
/// `ImageRenderer` produced, and the recorded one arrives through a PNG
/// decoder, and comparing those two directly compares their *encodings* as much
/// as their contents. A difference in `bytesPerRow`, in byte order, or in which
/// end the alpha channel sits at is a difference in every pixel.
struct SnapshotBitmap: Equatable, Sendable {

    /// Bytes per pixel in ``pixels``: red, green, blue, alpha, in that order.
    static let channelsPerPixel = 4

    let extent: SnapshotExtent

    /// `extent.pixelCount * channelsPerPixel` bytes.
    let pixels: [UInt8]

    init(extent: SnapshotExtent, pixels: [UInt8]) {
        self.extent = extent
        self.pixels = pixels
    }
}

extension SnapshotBitmap {

    /// Draws `image` into a context of this type's one layout and keeps the
    /// bytes.
    ///
    /// The flip is not decoration. Core Graphics draws an image into a
    /// bottom-left origin, so without it row 0 of ``pixels`` is the bottom row
    /// of the picture and every coordinate this file reports — a region, a diff
    /// — is upside down with respect to the image somebody is looking at.
    init?(_ image: CGImage) {
        let extent = SnapshotExtent(width: image.width, height: image.height)
        guard extent.width > 0, extent.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let rowBytes = extent.width * Self.channelsPerPixel
        let byteCount = rowBytes * extent.height
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
        defer { buffer.deallocate() }
        _ = buffer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        guard let context = CGContext(
            data: buffer,
            width: extent.width,
            height: extent.height,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.translateBy(x: 0, y: CGFloat(extent.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: CGFloat(extent.width), height: CGFloat(extent.height))
        )

        let bytes = UnsafeRawBufferPointer(start: buffer, count: byteCount)
        self.init(extent: extent, pixels: [UInt8](bytes))
    }

    /// Decodes a recorded golden.
    ///
    /// ImageIO rather than `UIImage(data:)` so that this file needs no UIKit and
    /// its tests need no simulator window: everything here is arithmetic over
    /// bytes, and the suite that checks it builds synthetic bitmaps by hand.
    static func decoding(pngData: Data) -> SnapshotBitmap? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return SnapshotBitmap(image)
    }

    var cgImage: CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: extent.width,
            height: extent.height,
            bitsPerComponent: 8,
            bitsPerPixel: 8 * Self.channelsPerPixel,
            bytesPerRow: extent.width * Self.channelsPerPixel,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    func pngData() -> Data? {
        guard let image = cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// The four bytes of one pixel.
    func pixel(x: Int, y: Int) -> [UInt8] {
        let offset = (y * extent.width + x) * Self.channelsPerPixel
        return Array(pixels[offset ..< offset + Self.channelsPerPixel])
    }
}
