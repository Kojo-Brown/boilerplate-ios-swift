import SwiftUI

/// A scanner-style targeting reticle rendered over the camera preview.
///
/// Dims the area outside the finder window, draws corner-bracket markers, and
/// animates a horizontal scan line so the UI communicates that the scanner is live.
struct ScannerOverlayView: View {
    let isScanning: Bool

    @State private var scanLineOffset: CGFloat = 0
    @State private var scanLineAnimating = false

    private let cornerLength: CGFloat = 28
    private let cornerWidth: CGFloat = 4
    private let finderRatio: CGFloat = 0.72

    var body: some View {
        GeometryReader { geometry in
            let finderSize = geometry.size.width * finderRatio
            let finderOriginX = (geometry.size.width - finderSize) / 2
            let finderOriginY = (geometry.size.height - finderSize) / 2
            let finderRect = CGRect(
                x: finderOriginX,
                y: finderOriginY,
                width: finderSize,
                height: finderSize
            )

            ZStack {
                dimOverlay(in: geometry.size, clearing: finderRect)
                cornerBrackets(at: finderRect)
                if isScanning {
                    scanLine(in: finderRect)
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: isScanning) { _, scanning in
            if scanning { startScanLineAnimation() } else { scanLineAnimating = false }
        }
        .onAppear {
            if isScanning { startScanLineAnimation() }
        }
    }

    // MARK: - Dimmed outer overlay with cut-out

    private func dimOverlay(in size: CGSize, clearing rect: CGRect) -> some View {
        Color.black.opacity(0.55)
            .mask(
                Rectangle()
                    .fill(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY),
                        alignment: .topLeading
                    )
                    .compositingGroup()
                    .luminanceToAlpha()
                    .ignoresSafeArea()
            )
    }

    // MARK: - Corner bracket markers

    private func cornerBrackets(at rect: CGRect) -> some View {
        let color = Color.white
        let r: CGFloat = 8

        return ZStack {
            // Top-left
            cornerPath(origin: CGPoint(x: rect.minX, y: rect.minY), quadrant: .topLeft, r: r)
                .stroke(color, style: StrokeStyle(lineWidth: cornerWidth, lineCap: .round))

            // Top-right
            cornerPath(origin: CGPoint(x: rect.maxX, y: rect.minY), quadrant: .topRight, r: r)
                .stroke(color, style: StrokeStyle(lineWidth: cornerWidth, lineCap: .round))

            // Bottom-left
            cornerPath(origin: CGPoint(x: rect.minX, y: rect.maxY), quadrant: .bottomLeft, r: r)
                .stroke(color, style: StrokeStyle(lineWidth: cornerWidth, lineCap: .round))

            // Bottom-right
            cornerPath(origin: CGPoint(x: rect.maxX, y: rect.maxY), quadrant: .bottomRight, r: r)
                .stroke(color, style: StrokeStyle(lineWidth: cornerWidth, lineCap: .round))
        }
    }

    // MARK: - Animated scan line

    private func scanLine(in rect: CGRect) -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, Color.green.opacity(0.9), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: rect.width - 8, height: 2)
            .position(x: rect.midX, y: rect.minY + scanLineOffset)
            .clipped()
            .animation(
                scanLineAnimating
                    ? .easeInOut(duration: 1.6).repeatForever(autoreverses: true)
                    : .default,
                value: scanLineOffset
            )
    }

    // MARK: - Helpers

    private enum CornerQuadrant {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private func cornerPath(origin: CGPoint, quadrant: CornerQuadrant, r: CGFloat) -> Path {
        Path { path in
            let len = cornerLength
            switch quadrant {
            case .topLeft:
                path.move(to: CGPoint(x: origin.x, y: origin.y + len))
                path.addLine(to: CGPoint(x: origin.x, y: origin.y + r))
                path.addQuadCurve(to: CGPoint(x: origin.x + r, y: origin.y), control: origin)
                path.addLine(to: CGPoint(x: origin.x + len, y: origin.y))
            case .topRight:
                path.move(to: CGPoint(x: origin.x - len, y: origin.y))
                path.addLine(to: CGPoint(x: origin.x - r, y: origin.y))
                path.addQuadCurve(to: CGPoint(x: origin.x, y: origin.y + r), control: origin)
                path.addLine(to: CGPoint(x: origin.x, y: origin.y + len))
            case .bottomLeft:
                path.move(to: CGPoint(x: origin.x, y: origin.y - len))
                path.addLine(to: CGPoint(x: origin.x, y: origin.y - r))
                path.addQuadCurve(to: CGPoint(x: origin.x + r, y: origin.y), control: origin)
                path.addLine(to: CGPoint(x: origin.x + len, y: origin.y))
            case .bottomRight:
                path.move(to: CGPoint(x: origin.x - len, y: origin.y))
                path.addLine(to: CGPoint(x: origin.x - r, y: origin.y))
                path.addQuadCurve(to: CGPoint(x: origin.x, y: origin.y - r), control: origin)
                path.addLine(to: CGPoint(x: origin.x, y: origin.y - len))
            }
        }
    }

    private func startScanLineAnimation() {
        scanLineOffset = 0
        scanLineAnimating = false
        // One-frame delay lets SwiftUI register the initial value before animating.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            scanLineAnimating = true
            // Drive offset to near the bottom of the finder; the animation reverses.
            scanLineOffset = 240
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.gray
            .ignoresSafeArea()
        ScannerOverlayView(isScanning: true)
    }
}
