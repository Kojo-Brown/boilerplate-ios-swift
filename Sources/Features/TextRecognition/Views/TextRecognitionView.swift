import SwiftUI
import UIKit

/// Full-screen camera view with live MLKit text recognition overlay.
///
/// Shows the camera feed, draws bounding boxes over each recognized text block,
/// and displays the full recognized string in a scrollable panel at the bottom.
/// Navigation entry point: `coordinator.push(.textRecognition)`.
struct TextRecognitionView: View {
    @State private var viewModel = TextRecognitionViewModel()
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        ZStack(alignment: .bottom) {
            cameraLayer
            if let result = viewModel.recognitionResult {
                recognitionOverlay(result: result)
            }
            if viewModel.permissionDenied {
                permissionDeniedBanner
            }
        }
        .ignoresSafeArea(edges: .horizontal)
        .navigationTitle("Text Scanner")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                scanToggle
            }
        }
        .task { await viewModel.onAppear() }
        .onDisappear { viewModel.onDisappear() }
    }

    // MARK: - Camera layer

    private var cameraLayer: some View {
        GeometryReader { geometry in
            ZStack {
                CameraPreviewView(previewLayer: viewModel.previewLayer)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                if let result = viewModel.recognitionResult {
                    blockOverlays(result: result, in: geometry.size)
                }
            }
        }
    }

    // MARK: - Block bounding-box overlay

    @ViewBuilder
    private func blockOverlays(result: RecognitionResult, in size: CGSize) -> some View {
        ForEach(result.blocks) { block in
            let frame = denormalized(rect: block.normalizedFrame, in: size)
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.yellow.opacity(0.8), lineWidth: 2)
                .frame(width: frame.width, height: frame.height)
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

    private func recognitionOverlay(result: RecognitionResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(result: result)
            Divider()
            ScrollView {
                Text(result.fullText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(maxHeight: 180)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding()
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: result.fullText)
    }

    private func header(result: RecognitionResult) -> some View {
        HStack {
            Label("\(result.blocks.count) block\(result.blocks.count == 1 ? "" : "s") detected", systemImage: "text.viewfinder")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            copyButton
            clearButton
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var copyButton: some View {
        Button {
            viewModel.copyToClipboard()
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

    // MARK: - Scan toggle

    private var scanToggle: some View {
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
        TextRecognitionView()
            .environment(AppCoordinator())
    }
}
