import SwiftUI
import UIKit

/// Full-screen camera view with Vision-powered barcode and QR code scanning overlay.
///
/// Shows the camera feed, a targeting reticle, per-barcode bounding-box highlights,
/// and a results panel at the bottom when a code is detected.
/// Navigation entry point: `coordinator.push(.barcodeScanner)`.
struct BarcodeScannerView: View {
    @State private var viewModel = BarcodeScannerViewModel()
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        ZStack(alignment: .bottom) {
            cameraLayer
            ScannerOverlayView(isScanning: viewModel.isScanning)
            if let result = viewModel.scanResult {
                resultPanel(result: result)
            }
            if viewModel.permissionDenied {
                permissionDeniedBanner
            }
        }
        .ignoresSafeArea(edges: .horizontal)
        .navigationTitle("Barcode Scanner")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { scanToggle }
        .task { await viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
    }

    // MARK: - Camera layer

    private var cameraLayer: some View {
        GeometryReader { geometry in
            ZStack {
                CameraPreviewView(previewLayer: viewModel.previewLayer)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                if let result = viewModel.scanResult {
                    barcodeHighlights(result: result, in: geometry.size)
                }
            }
        }
    }

    // MARK: - Per-barcode bounding-box highlights

    @ViewBuilder
    private func barcodeHighlights(result: ScanResult, in size: CGSize) -> some View {
        ForEach(result.barcodes) { barcode in
            let frame = denormalized(rect: barcode.normalizedFrame, in: size)
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.green.opacity(0.9), lineWidth: 2)
                    .frame(width: frame.width, height: frame.height)
                Text(barcode.symbology.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.8), in: Capsule())
                    .offset(y: -(frame.height / 2 + 14))
            }
            .position(x: frame.midX, y: frame.midY)
        }
    }

    private func denormalized(rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * size.width,
            y: rect.minY * size.height,
            width: rect.width * size.width,
            height: rect.height * size.height
        )
    }

    // MARK: - Results panel

    private func resultPanel(result: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(result: result)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(result.barcodes) { barcode in
                        barcodeRow(barcode)
                    }
                }
                .padding()
            }
            .frame(maxHeight: 200)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding()
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: result.barcodes.count)
    }

    private func panelHeader(result: ScanResult) -> some View {
        HStack {
            Label(
                "\(result.barcodes.count) code\(result.barcodes.count == 1 ? "" : "s") detected",
                systemImage: "qrcode.viewfinder"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            Spacer()
            copyButton
            clearButton
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func barcodeRow(_ barcode: DetectedBarcode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(barcode.symbology.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(barcode.payload)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    private var copyButton: some View {
        Button {
            viewModel.copyPayload()
        } label: {
            Label(
                viewModel.didCopyToClipboard ? "Copied!" : "Copy",
                systemImage: viewModel.didCopyToClipboard ? "checkmark" : "doc.on.doc"
            )
            .font(.subheadline)
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(viewModel.didCopyToClipboard ? .green : .accentColor)
        .animation(.default, value: viewModel.didCopyToClipboard)
    }

    private var clearButton: some View {
        Button {
            viewModel.clearResult()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar

    private var scanToggle: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                if viewModel.isScanning {
                    viewModel.stop()
                } else {
                    Task { await viewModel.startScanning() }
                }
            } label: {
                Image(systemName: viewModel.isScanning ? "pause.circle" : "play.circle")
                    .imageScale(.large)
            }
            .disabled(viewModel.permissionDenied)
        }
    }

    // MARK: - Permission denied banner

    private var permissionDeniedBanner: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Camera Access Required")
                .font(.headline)
            Text("Go to Settings > Privacy > Camera and enable access for this app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding()
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        BarcodeScannerView()
            .environment(AppCoordinator())
    }
}
