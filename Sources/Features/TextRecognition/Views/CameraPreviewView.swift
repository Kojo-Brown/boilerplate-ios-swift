import AVFoundation
import SwiftUI
import UIKit

/// A SwiftUI wrapper around `AVCaptureVideoPreviewLayer`.
///
/// Pass in the `previewLayer` from `CameraService` and it will fill its container,
/// automatically updating the layer frame on layout changes.
struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context _: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.attach(previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context _: Context) {
        uiView.attach(previewLayer)
    }
}

// MARK: - Backing UIView

extension CameraPreviewView {
    /// A plain `UIView` whose only job is to host a `AVCaptureVideoPreviewLayer`.
    final class PreviewHostView: UIView {
        private var hostedLayer: AVCaptureVideoPreviewLayer?

        func attach(_ layer: AVCaptureVideoPreviewLayer) {
            guard layer !== hostedLayer else { return }
            hostedLayer?.removeFromSuperlayer()
            layer.frame = bounds
            self.layer.insertSublayer(layer, at: 0)
            hostedLayer = layer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            hostedLayer?.frame = bounds
        }
    }
}
