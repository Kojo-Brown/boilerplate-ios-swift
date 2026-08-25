import AVFoundation
import SwiftUI
import UIKit

/// A SwiftUI wrapper around `AVCaptureVideoPreviewLayer`.
///
/// Pass in the `previewLayer` from `CameraService` and it will fill its container,
/// automatically updating the layer frame on layout changes.
package struct CameraPreviewView: UIViewRepresentable {
    package let previewLayer: AVCaptureVideoPreviewLayer

    package func makeUIView(context _: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.attach(previewLayer)
        return view
    }

    package func updateUIView(_ uiView: PreviewHostView, context _: Context) {
        uiView.attach(previewLayer)
    }
}

// MARK: - Backing UIView

extension CameraPreviewView {
    /// A plain `UIView` whose only job is to host a `AVCaptureVideoPreviewLayer`.
    package final class PreviewHostView: UIView {
        private var hostedLayer: AVCaptureVideoPreviewLayer?

        package func attach(_ layer: AVCaptureVideoPreviewLayer) {
            guard layer !== hostedLayer else { return }
            hostedLayer?.removeFromSuperlayer()
            layer.frame = bounds
            self.layer.insertSublayer(layer, at: 0)
            hostedLayer = layer
        }

        package override func layoutSubviews() {
            super.layoutSubviews()
            hostedLayer?.frame = bounds
        }
    }
}
